#!/usr/bin/env python3
"""Dessine l'icône de l'app : une page, et le passage qui répond.

C'est tout le propos de L'Atelier — pas « chercher », mais **retrouver le passage exact**
et le montrer. La feuille est claire sur le bleu encre de l'app, les lignes de texte sont
sourdes, et une seule est surlignée d'or.

Rien d'autre n'est nécessaire : ni Mac, ni Xcode, ni police installée. Xcode décline seul
toutes les tailles à partir de ce fichier de 1024 pixels.

    python3 Tools/make-icon.py [encre|papier|lettre]
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

SIDE = 1024
SUPERSAMPLE = 4          # dessiné en 4096 puis réduit : les bords restent nets

INK = (0x1F, 0x3A, 0x5F)      # bleu encre, la valeur d'AccentColor en mode clair
PAPER = (0xF5, 0xF1, 0xE9)    # blanc cassé, chaud
MUTED = (0xB8, 0xC2, 0xD1)    # les lignes de texte, présentes sans se lire
GOLD = (0xC8, 0x9B, 0x3C)     # le passage retrouvé


def _scaler():
    def s(value):
        return int(round(value * SUPERSAMPLE))
    return s


def page(background, sheet, text, outlined):
    """La feuille et ses lignes. `outlined` la dessine en contour plutôt qu'en aplat."""
    s = _scaler()
    image = Image.new("RGB", (SIDE * SUPERSAMPLE, SIDE * SUPERSAMPLE), background)
    pen = ImageDraw.Draw(image)

    left, top, width, height = 272, 188, 480, 648
    box = [s(left), s(top), s(left + width), s(top + height)]
    if outlined:
        pen.rounded_rectangle(box, radius=s(30), outline=sheet, width=s(26))
    else:
        pen.rounded_rectangle(box, radius=s(30), fill=sheet)

    # Quatre lignes seulement : à quatre-vingt-seize pixels, cinq deviennent une trame grise.
    # La troisième porte le surligneur — un peu plus haute, comme un vrai trait de feutre.
    margin, y, spacing = 64, top + 128, 132
    for index, length in enumerate([264, 352, 352, 208]):
        if index == 2:
            pen.rounded_rectangle(
                [s(left + margin), s(y - 22), s(left + margin + length), s(y + 56)],
                radius=s(18), fill=GOLD,
            )
        else:
            pen.rounded_rectangle(
                [s(left + margin), s(y), s(left + margin + length), s(y + 34)],
                radius=s(17), fill=text,
            )
        y += spacing

    return image.resize((SIDE, SIDE), Image.LANCZOS)


def letter(background, stroke):
    """Variante typographique : le A construit au trait, barré du même surligneur."""
    s = _scaler()
    image = Image.new("RGB", (SIDE * SUPERSAMPLE, SIDE * SUPERSAMPLE), background)
    pen = ImageDraw.Draw(image)
    apex_y, foot_y, half, centre = 246, 792, 46, 512
    for foot in (268, 756):
        pen.polygon(
            [
                (s(centre - half), s(apex_y)), (s(centre + half), s(apex_y)),
                (s(foot + half), s(foot_y)), (s(foot - half), s(foot_y)),
            ],
            fill=stroke,
        )
    pen.rectangle([s(372), s(600), s(830), s(668)], fill=GOLD)
    return image.resize((SIDE, SIDE), Image.LANCZOS)


VARIANTS = {
    "encre": lambda: page(INK, PAPER, MUTED, outlined=False),
    "papier": lambda: page(PAPER, INK, INK, outlined=True),
    "lettre": lambda: letter(INK, PAPER),
}


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "encre"
    if name not in VARIANTS:
        raise SystemExit(f"Variante inconnue : {name}. Au choix : {', '.join(VARIANTS)}.")

    output = Path(__file__).resolve().parent.parent / (
        "Atelier/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    )
    VARIANTS[name]().save(output)
    print(f"icône « {name} » écrite : {output}")


if __name__ == "__main__":
    main()
