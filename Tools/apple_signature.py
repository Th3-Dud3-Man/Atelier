#!/usr/bin/env python3
"""Crée, chez Apple, le certificat et le profil nécessaires à la signature de L'Atelier.

Tout passe par l'API App Store Connect, donc depuis n'importe quelle machine : aucun Mac
n'est nécessaire, et rien n'est demandé à l'utilisateur en dehors de sa clé d'API.

Les formats employés viennent de la documentation officielle :
  POST /v1/certificates  → CertificateCreateRequest {data:{type, attributes:{certificateType, csrContent}}}
  POST /v1/profiles      → ProfileCreateRequest {data:{type, attributes:{name, profileType},
                            relationships:{bundleId, certificates}}}
  POST /v1/bundleIds     → BundleIdCreateRequest {data:{type, attributes:{identifier, name, platform}}}
Le jeton est un JWT ES256 dont l'en-tête porte `kid` et la charge `iss`, `iat`, `exp`, `aud`
(« appstoreconnect-v1 »), avec une validité de vingt minutes au plus.

La clé privée du certificat est produite ici et ne quitte jamais l'exécution : elle est
déposée telle quelle dans les secrets du dépôt, jamais affichée.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = "https://api.appstoreconnect.apple.com"
AUDIENCE = "appstoreconnect-v1"


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"::error::{message}")
    sys.exit(1)


def note(message: str) -> None:
    print(message, flush=True)


# ── Jeton ────────────────────────────────────────────────────────────────────

def make_token(key_id: str, issuer_id: str, private_key: str) -> str:
    try:
        import jwt  # PyJWT
    except ImportError:
        fail("PyJWT n'est pas installé (pip install 'pyjwt[crypto]').")
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 15 * 60, "aud": AUDIENCE},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


# ── Appels ───────────────────────────────────────────────────────────────────

def call(token: str, method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        try:
            errors = json.loads(detail).get("errors", [])
            detail = " | ".join(
                f"{e.get('title', '')} — {e.get('detail', '')}".strip(" —") for e in errors
            ) or detail
        except Exception:
            pass
        fail(f"{method} {path} a échoué ({error.code}) : {detail}")
    except urllib.error.URLError as error:
        fail(f"{method} {path} : {error.reason}")


# ── Étapes ───────────────────────────────────────────────────────────────────

def ensure_bundle_id(token: str, identifier: str, name: str) -> str:
    found = call(token, "GET", f"/v1/bundleIds?filter[identifier]={identifier}&limit=200")
    for item in found.get("data", []):
        if item.get("attributes", {}).get("identifier") == identifier:
            note(f"Identifiant {identifier} : déjà déclaré.")
            return item["id"]

    created = call(token, "POST", "/v1/bundleIds", {
        "data": {
            "type": "bundleIds",
            "attributes": {"identifier": identifier, "name": name, "platform": "IOS"},
        }
    })
    note(f"Identifiant {identifier} : créé.")
    return created["data"]["id"]


def create_certificate(token: str, csr: str, revoke_oldest: bool) -> tuple[str, str]:
    """Renvoie (identifiant, certificat au format PEM)."""
    existing = call(token, "GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=200")
    certificates = existing.get("data", [])
    note(f"Certificats de distribution déjà chez Apple : {len(certificates)}.")

    if certificates and revoke_oldest:
        oldest = min(
            certificates,
            key=lambda c: c.get("attributes", {}).get("expirationDate") or "",
        )
        label = oldest.get("attributes", {}).get("displayName", oldest["id"])
        call(token, "DELETE", f"/v1/certificates/{oldest['id']}")
        note(f"Certificat révoqué à votre demande : {label}.")

    created = call(token, "POST", "/v1/certificates", {
        "data": {
            "type": "certificates",
            "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr},
        }
    })
    attributes = created["data"]["attributes"]
    content = attributes["certificateContent"]
    note(f"Certificat créé : {attributes.get('displayName', '')}, "
         f"valable jusqu'au {attributes.get('expirationDate', '')[:10]}.")

    pem = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-outform", "PEM"],
        input=__import__("base64").b64decode(content),
        capture_output=True, check=True,
    ).stdout.decode()
    return created["data"]["id"], pem


def create_profile(token: str, name: str, bundle_id: str, certificate_id: str) -> str:
    """Supprime un profil homonyme puis en crée un neuf. Renvoie son contenu en base64."""
    existing = call(token, "GET", "/v1/profiles?limit=200")
    for item in existing.get("data", []):
        if item.get("attributes", {}).get("name") == name:
            call(token, "DELETE", f"/v1/profiles/{item['id']}")
            note(f"Ancien profil « {name} » retiré.")

    created = call(token, "POST", "/v1/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"id": bundle_id, "type": "bundleIds"}},
                "certificates": {"data": [{"id": certificate_id, "type": "certificates"}]},
            },
        }
    })
    attributes = created["data"]["attributes"]
    note(f"Profil « {name} » créé, valable jusqu'au {attributes.get('expirationDate', '')[:10]}.")
    return attributes["profileContent"]


def team_id_from_profile(profile_base64: str) -> str:
    """Le profil est une enveloppe signée qui contient sa liste de propriétés en clair."""
    raw = __import__("base64").b64decode(profile_base64)
    match = re.search(rb"<\?xml.*?</plist>", raw, re.S)
    if not match:
        fail("Le profil ne contient pas la liste de propriétés attendue.")
    text = match.group(0).decode("utf-8", "replace")
    prefix = re.search(
        r"<key>ApplicationIdentifierPrefix</key>\s*<array>\s*<string>([^<]+)</string>", text
    )
    if prefix:
        return prefix.group(1)
    team = re.search(r"<key>TeamIdentifier</key>\s*<array>\s*<string>([^<]+)</string>", text)
    if team:
        return team.group(1)
    fail("Identifiant d'équipe introuvable dans le profil.")


# ── Déroulé ──────────────────────────────────────────────────────────────────

def main() -> None:
    key_id = os.environ.get("ASC_KEY_ID", "").strip()
    issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
    private_key = os.environ.get("ASC_PRIVATE_KEY", "")
    bundle_identifier = os.environ.get("BUNDLE_ID", "com.bureau.latelier").strip()
    profile_name = os.environ.get("PROFILE_NAME", "Atelier App Store").strip()
    csr_path = os.environ.get("CSR_PATH", "")
    out_dir = os.environ.get("OUT_DIR", "")
    revoke_oldest = os.environ.get("REVOKE_OLDEST", "").lower() in {"true", "1", "oui"}

    for name, value in [("ASC_KEY_ID", key_id), ("ASC_ISSUER_ID", issuer_id),
                        ("ASC_PRIVATE_KEY", private_key), ("CSR_PATH", csr_path),
                        ("OUT_DIR", out_dir)]:
        if not value:
            fail(f"{name} est vide.")
    if "PRIVATE KEY" not in private_key:
        fail("ASC_PRIVATE_KEY ne ressemble pas à une clé .p8 : les lignes BEGIN et END "
             "doivent en faire partie.")

    with open(csr_path, encoding="utf-8") as handle:
        csr = handle.read()

    token = make_token(key_id, issuer_id, private_key)

    bundle_id = ensure_bundle_id(token, bundle_identifier, "L Atelier")
    certificate_id, certificate_pem = create_certificate(token, csr, revoke_oldest)
    profile_base64 = create_profile(token, profile_name, bundle_id, certificate_id)
    team = team_id_from_profile(profile_base64)
    note(f"Équipe : {team}.")

    os.makedirs(out_dir, exist_ok=True)
    for filename, content in [
        ("certificat.pem", certificate_pem),
        ("profil.base64", profile_base64),
        ("equipe.txt", team),
        ("profil-nom.txt", profile_name),
    ]:
        path = os.path.join(out_dir, filename)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(path, 0o600)
    note("Pièces écrites, prêtes à être déposées dans les secrets.")


if __name__ == "__main__":
    main()
