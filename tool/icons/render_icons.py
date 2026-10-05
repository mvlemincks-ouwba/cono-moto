#!/usr/bin/env python3
"""Rendu des icônes iOS de Cono Moto (cône orange penché + route sinueuse sur
fond asphalte #121519), même visuel que l'icône Android.

    pip install pillow
    python3 tool/icons/render_icons.py

Écrit :
  ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png  (sans transparence)
  ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage*.png (logo, fond transparent)

Le dessin est décrit dans un repère 192 × 192 (celui de l'icône Android
historique), rendu en sur-échantillonnage ×4 puis réduit (Lanczos).
"""

from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
APPICON = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
LAUNCH = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'LaunchImage.imageset')

ASPHALT = (18, 21, 25)
ROAD = (52, 58, 70)
CONE = (255, 107, 26)
CONE_BASE = (214, 74, 8)
WHITE = (255, 255, 255)

# Axe de la route (repère 192), relevé sur l'icône Android, prolongé hors cadre.
ROAD_AXIS = [
    (92, -30), (78, 0), (72.5, 24), (80, 46), (100, 70), (126, 96),
    (146, 119), (157, 145), (151, 167), (134, 188), (116, 212),
]
ROAD_WIDTH = 37.5
DASH_WIDTH = 2.3
DASH_LEN = 8.0
DASH_GAP = 8.0

# Cône (repère local : origine au centre de la base, y vers le haut), puis
# incliné de 15,5° vers la gauche autour du centre de la base.
CONE_BASE_CENTER = (67.5, 149.5)
CONE_TILT_DEG = 15.5
CONE_HEIGHT = 104.0
CONE_BOTTOM_HALF = 34.0
CONE_TOP_HALF = 4.5
BAR_HALF_LEN = 50.0
BAR_HALF_THICK = 5.8
STRIPE = (0.50, 0.63)  # bande blanche : fraction de la hauteur depuis la base


def catmull_rom(points, steps=24):
    out = []
    pts = [points[0]] + points + [points[-1]]
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for s in range(steps):
            t = s / steps
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    out.append(points[-1])
    return out


def resample(line, step):
    """Points régulièrement espacés de `step` le long de la polyligne."""
    out = [line[0]]
    carry = 0.0
    for i in range(1, len(line)):
        a, b = line[i - 1], line[i]
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        t = step - carry
        while t <= L:
            out.append((a[0] + (b[0] - a[0]) * t / L, a[1] + (b[1] - a[1]) * t / L))
            t += step
        carry = L - (t - step)
    return out


def sweep(draw, line, radius, color, P, k):
    """Trace un trait épais aux bouts ronds en empilant des disques."""
    r = radius * k
    for q in resample(line, max(0.02, radius / 6)):
        x, y = P(q)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color + (255,))


def cone_shapes():
    """Polygones du cône dans le repère 192 (après inclinaison)."""
    a = math.radians(CONE_TILT_DEG)
    cx, cy = CONE_BASE_CENTER

    def tr(lx, ly):
        # ly vers le haut ; rotation : le haut part vers la gauche.
        x = lx * math.cos(a) - ly * math.sin(a)
        y = lx * math.sin(a) + ly * math.cos(a)
        return (cx + x, cy - y)

    def body_half(h):
        return CONE_BOTTOM_HALF + (CONE_TOP_HALF - CONE_BOTTOM_HALF) * (h / CONE_HEIGHT)

    # Corps : trapèze au sommet arrondi.
    body = [tr(-CONE_BOTTOM_HALF, 0), tr(CONE_BOTTOM_HALF, 0)]
    for k in range(0, 13):
        ang = math.pi * k / 12  # demi-cercle du sommet, de droite à gauche
        body.append(tr(CONE_TOP_HALF * math.cos(ang), CONE_HEIGHT + CONE_TOP_HALF * 0.9 * math.sin(ang)))
    stripe_lo, stripe_hi = STRIPE[0] * CONE_HEIGHT, STRIPE[1] * CONE_HEIGHT
    stripe = [tr(-body_half(stripe_lo), stripe_lo), tr(body_half(stripe_lo), stripe_lo),
              tr(body_half(stripe_hi), stripe_hi), tr(-body_half(stripe_hi), stripe_hi)]
    # Barre de base : rectangle aux bouts ronds.
    bar = []
    for k in range(0, 13):
        ang = -math.pi / 2 + math.pi * k / 12
        bar.append(tr(BAR_HALF_LEN - BAR_HALF_THICK + BAR_HALF_THICK * math.cos(ang),
                      -BAR_HALF_THICK * 0.6 + BAR_HALF_THICK * math.sin(ang)))
    for k in range(0, 13):
        ang = math.pi / 2 + math.pi * k / 12
        bar.append(tr(-BAR_HALF_LEN + BAR_HALF_THICK + BAR_HALF_THICK * math.cos(ang),
                      -BAR_HALF_THICK * 0.6 + BAR_HALF_THICK * math.sin(ang)))
    return body, stripe, bar


def render(size, *, background: bool, road_clip=None, content_scale=0.93):
    """Rend le logo en carré `size` px. road_clip=(y0, y1) coupe la route
    horizontalement (repère 192) pour l'écran de lancement."""
    ss = 4
    S = size * ss
    img = Image.new('RGBA', (S, S), ASPHALT + (255,) if background else (0, 0, 0, 0))
    k = S / 192.0 * content_scale
    off = S * (1 - content_scale) / 2

    def P(p):
        return (off + p[0] * k, off + p[1] * k)

    axis = catmull_rom(ROAD_AXIS)
    if road_clip:
        y0, y1 = road_clip
        axis = [p for p in axis if y0 <= p[1] <= y1]

    # Route : balayage d'un disque le long de l'axe (bords lisses, sans
    # auto-intersection dans les virages serrés).
    road_layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(road_layer)
    sweep(d, axis, ROAD_WIDTH / 2, ROAD, P, k)

    # Pointillés blancs le long de l'axe (bouts arrondis).
    dense = resample(axis, 0.05)
    period = DASH_LEN + DASH_GAP
    dash = []
    for i, q in enumerate(dense):
        if (i * 0.05) % period < DASH_LEN:
            dash.append(q)
        elif dash:
            sweep(d, dash, DASH_WIDTH / 2, WHITE, P, k)
            dash = []
    if dash:
        sweep(d, dash, DASH_WIDTH / 2, WHITE, P, k)
    if road_clip:
        # Bouts plats : on efface ce qui dépasse de la bande.
        y0, y1 = road_clip
        mask = Image.new('L', (S, S), 0)
        ImageDraw.Draw(mask).rectangle([0, P((0, y0))[1], S, P((0, y1))[1]], fill=255)
        empty = Image.new('RGBA', (S, S), (0, 0, 0, 0))
        road_layer = Image.composite(road_layer, empty, mask)
    img.alpha_composite(road_layer)

    body, stripe, bar = cone_shapes()
    d = ImageDraw.Draw(img)
    d.polygon([P(p) for p in body], fill=CONE + (255,))
    d.polygon([P(p) for p in stripe], fill=WHITE + (255,))
    d.polygon([P(p) for p in bar], fill=CONE_BASE + (255,))

    return img.resize((size, size), Image.LANCZOS)


APP_ICONS = {
    'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76, 'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
}

LAUNCH_PT = 144  # taille du logo sur l'écran de lancement (points)


def main():
    master = render(1024, background=True)
    for name, px in APP_ICONS.items():
        im = master if px == 1024 else master.resize((px, px), Image.LANCZOS)
        # iOS refuse la transparence sur l'icône : on aplatit en RGB.
        im.convert('RGB').save(os.path.join(APPICON, name), optimize=True)
    for suffix, scale in (('', 1), ('@2x', 2), ('@3x', 3)):
        im = render(LAUNCH_PT * scale, background=False, road_clip=(10, 182), content_scale=0.62)
        im.save(os.path.join(LAUNCH, f'LaunchImage{suffix}.png'), optimize=True)
    print('Icônes iOS écrites dans', APPICON)
    return 0


if __name__ == '__main__':
    sys.exit(main())
