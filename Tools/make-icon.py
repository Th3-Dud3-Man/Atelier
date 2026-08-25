#!/usr/bin/env python3
"""Dessine l'icône de l'app : un « A » construit au trait, barré d'un surligneur.

Le A dit le nom, la barre dit ce que fait l'app — retrouver le passage qui répond.
Elle dépasse la lettre à droite, pour que la marque ne se lise pas comme une simple
initiale posée là.

Rien d'autre n'est nécessaire : ni Mac, ni Xcode, ni police installée. Xcode décline
seul toutes les tailles à partir de ce fichier de 1024 pixels.

    python3 Tools/make-icon.py [encre|papier|sobre]
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

SIDE = 1024
SUPERSAMPLE = 4          # dessiné en 4096 puis réduit : les diagonales restent nettes

INK = (0x1F, 0x3A, 0x5F)     # bleu encre, la valeur d'AccentColor en mode clair
PAPER = (0xF5, 0xF1, 0xE9)   # blanc cassé, chaud
WHITE = (0xFF, 0xFF, 0xFF)
GOLD = (0xC8, 0x9B, 0x3C)    # le trait de surligneur

VARIANTS = {
    "encre": (INK, WHITE, GOLD),
    "papier": (PAPER, INK, GOLD),
    "sobre": (INK, WHITE, WHITE),
}


def draw(background, stroke, bar):
    scale = SUPERSAMPLE

    def s(value):
        return int(round(value * scale))

    image = Image.new("RGB", (SIDE * scale, SIDE * scale), background)
    pen = ImageDraw.Draw(image)

    apex_y, foot_y = 246, 792
    half = 46                      # demi-épaisseur, mesurée à l'horizontale
    centre, left_foot, right_foot = 512, 268, 756

    # Deux jambages posés en polygones plutôt qu'en traits épais : le sommet est net,
    # sans l'encoche que laisse la rencontre de deux lignes.
    for foot in (left_foot, right_foot):
        pen.polygon(
            [
                (s(centre - half), s(apex_y)),
                (s(centre + half), s(apex_y)),
                (s(foot + half), s(foot_y)),
                (s(foot - half), s(foot_y)),
            ],
            fill=stroke,
        )

    pen.rectangle([s(372), s(600), s(830), s(668)], fill=bar)
    return image.resize((SIDE, SIDE), Image.LANCZOS)


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "encre"
    if name not in VARIANTS:
        raise SystemExit(f"Variante inconnue : {name}. Au choix : {', '.join(VARIANTS)}.")

    output = Path(__file__).resolve().parent.parent / (
        "Atelier/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    )
    draw(*VARIANTS[name]).save(output)
    print(f"icône « {name} » écrite : {output}")


if __name__ == "__main__":
    main()
