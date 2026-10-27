#!/usr/bin/env python3
"""
ccimg - image <-> texte subpixel pour CC:Tweaked
=================================================

Convertit une image en texte "CCI1" (subpixel 2x3 par caractère, palette de
16 couleurs optimisée), et reconvertit ce texte en image PNG (aperçu).
Le texte est 100 % ASCII : il se transmet par HTTP, pastebin, copier-coller...

Utilisation :
  python ccimg.py serve   [--port 8888] [--token SECRET] [--dir data]
  python ccimg.py convert photo.png photo.cci [-W 51] [-H 19] [--cc]
  python ccimg.py render  photo.cci apercu.png [--scale 4]

Dépendances : pip install pillow numpy

Format CCI1
-----------
  ligne 1 : CCI1
  ligne 2 : <largeur> <hauteur>            (en caractères)
  ligne 3 : 16 couleurs RRGGBB séparées par des espaces (palette 0..f)
  puis <hauteur> lignes de 3*<largeur> caractères :
     - largeur caractères "motif" en base32 (0-9a-v) -> glyphe 0x80 + valeur
     - largeur caractères couleur de texte (hex 0-f, format blit)
     - largeur caractères couleur de fond   (hex 0-f, format blit)

Motif subpixel : bits 1,2 / 4,8 / 16,(fond) pour la grille 2x3
(haut-gauche, haut-droite, milieu-gauche, milieu-droite, bas-gauche ;
le pixel bas-droite est toujours la couleur de fond).

Routes HTTP
-----------
  GET  /ccimg.lua                       le programme Lua (installation via wget)
  GET  /list                            images et textes stockés
  GET  /convert?name=x.png&w=51&h=19    convertit une image stockée
  GET  /convert?url=https://...&w=&h=   télécharge puis convertit
       options : cc=1 (palette CC par défaut), save=nom (stocke le résultat)
  GET  /cci/<nom>                       récupère un texte partagé
  POST /cci/<nom>                       partage un texte (corps = texte CCI1)
  GET  /preview/<nom>                   texte partagé -> PNG (navigateur)
  POST /upload?name=x.png               dépose une image (corps = fichier brut)
  Avec --token, ajouter k=SECRET à chaque requête.
"""
import argparse
import io
import os
import re
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image

B32 = "0123456789abcdefghijklmnopqrstuv"
HEX = "0123456789abcdef"
MAX_W, MAX_H = 400, 200          # taille max en caractères
MAX_BODY = 10 * 1024 * 1024      # 10 Mo
NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")
HERE = os.path.dirname(os.path.abspath(__file__))

# Palette par défaut de CC:Tweaked, dans l'ordre blit 0..f
CC_PALETTE = [
    0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2, 0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C,
    0x999999, 0x4C99B2, 0xB266E5, 0x3366CC, 0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111,
]


# --------------------------------------------------------------------------
# Couleurs
# --------------------------------------------------------------------------
def hex_to_rgb(values):
    return np.array([[(c >> 16) & 255, (c >> 8) & 255, c & 255] for c in values], float) / 255


def srgb_to_oklab(rgb):
    """rgb : tableau (..., 3) en 0..1 -> Oklab (perceptuellement uniforme)."""
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    m1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
    m2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    return np.cbrt(lin @ m1.T) @ m2.T


def pick_palette(img, rgb, lab, n=16, iters=8):
    """Median cut (Pillow) puis quelques passes de k-means en Oklab."""
    q = img.quantize(colors=n, method=Image.Quantize.MEDIANCUT)
    raw = (q.getpalette() or [])[: n * 3]
    raw += [0] * (n * 3 - len(raw))
    pal = np.array(raw, float).reshape(n, 3) / 255
    flat_rgb, flat_lab = rgb.reshape(-1, 3), lab.reshape(-1, 3)
    for _ in range(iters):
        dist = ((flat_lab[:, None, :] - srgb_to_oklab(pal)[None]) ** 2).sum(-1)
        nearest = dist.argmin(1)
        for k in range(n):
            members = nearest == k
            if members.any():
                pal[k] = flat_rgb[members].mean(0)
    return pal


# --------------------------------------------------------------------------
# Image -> texte
# --------------------------------------------------------------------------
def load_image(data: bytes) -> Image.Image:
    img = Image.open(io.BytesIO(data))
    img.seek(0)                                   # 1re image d'un GIF animé
    img = img.convert("RGBA")
    background = Image.new("RGBA", img.size, (0, 0, 0, 255))
    return Image.alpha_composite(background, img).convert("RGB")


def fit(img, cols, rows):
    """Redimensionne pour tenir dans cols x rows caractères (2x3 subpixels chacun)."""
    pw, ph = cols * 2, rows * 3
    s = min(pw / img.width, ph / img.height)
    nw = max(2, int(img.width * s) // 2 * 2)
    nh = max(3, int(img.height * s) // 3 * 3)
    return img.resize((nw, nh), Image.LANCZOS)


def image_to_cci(img, cols=51, rows=19, cc_palette=False):
    img = fit(img, cols, rows)
    rgb = np.asarray(img, float) / 255
    lab = srgb_to_oklab(rgb)
    pal = hex_to_rgb(CC_PALETTE) if cc_palette else pick_palette(img, rgb, lab)
    pal_lab = srgb_to_oklab(pal)

    ph, pw = rgb.shape[:2]
    r, c = ph // 3, pw // 2
    # Blocs 2x3 -> (r, c, 6, 3), ordre : HG, HD, MG, MD, BG, BD
    blocks = lab.reshape(r, 3, c, 2, 3).transpose(0, 2, 1, 3, 4).reshape(r, c, 6, 3)
    dist = ((blocks[..., None, :] - pal_lab) ** 2).sum(-1)          # (r, c, 6, 16)

    # Meilleure paire de couleurs par caractère (120 paires testées)
    ia, ib = np.triu_indices(16, 1)
    cost = np.minimum(dist[..., ia], dist[..., ib]).sum(2)           # (r, c, 120)
    best = cost.argmin(-1)
    a, b = ia[best], ib[best]
    da = np.take_along_axis(dist, a[:, :, None, None], axis=3)[..., 0]
    db = np.take_along_axis(dist, b[:, :, None, None], axis=3)[..., 0]
    use_b = db < da                                                  # (r, c, 6)

    # Le pixel bas-droite impose la couleur de fond
    br = use_b[..., 5]
    bg = np.where(br, b, a)
    fg = np.where(br, a, b)
    is_fg = use_b != br[..., None]
    code = (is_fg[..., :5] * np.array([1, 2, 4, 8, 16])).sum(-1)
    fg = np.where(code == 0, bg, fg)

    pal_int = np.clip(np.round(pal * 255), 0, 255).astype(int)
    lines = ["CCI1", f"{c} {r}",
             " ".join(f"{p[0]:02x}{p[1]:02x}{p[2]:02x}" for p in pal_int)]
    for y in range(r):
        lines.append("".join(B32[v] for v in code[y])
                     + "".join(HEX[v] for v in fg[y])
                     + "".join(HEX[v] for v in bg[y]))
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Texte -> image
# --------------------------------------------------------------------------
def parse_cci(text):
    lines = text.replace("\r", "").split("\n")
    if not lines or lines[0].strip() != "CCI1":
        raise ValueError("en-tête CCI1 manquant")
    w, h = map(int, lines[1].split())
    if not (1 <= w <= MAX_W and 1 <= h <= MAX_H):
        raise ValueError("taille invalide")
    pal = [int(x, 16) for x in lines[2].split()]
    if len(pal) != 16:
        raise ValueError("la palette doit contenir 16 couleurs")
    rows = lines[3:3 + h]
    pattern = re.compile(f"[0-9a-v]{{{w}}}[0-9a-f]{{{2 * w}}}")
    if len(rows) < h or not all(pattern.fullmatch(row[:3 * w]) for row in rows):
        raise ValueError("lignes manquantes ou invalides")
    return w, h, pal, rows


def render_cci(text, scale=4):
    w, h, pal, rows = parse_cci(text)
    idx = np.empty((h * 3, w * 2), np.uint8)
    for y, row in enumerate(rows):
        for x in range(w):
            v, f, b = B32.index(row[x]), int(row[w + x], 16), int(row[2 * w + x], 16)
            cell = [f if (v >> bit) & 1 else b for bit in range(5)] + [b]
            idx[y * 3:y * 3 + 3, x * 2:x * 2 + 2] = np.array(cell).reshape(3, 2)
    colors = np.array([[(c >> 16) & 255, (c >> 8) & 255, c & 255] for c in pal], np.uint8)
    img = Image.fromarray(colors[idx], "RGB")
    if scale > 1:
        img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
    return img


# --------------------------------------------------------------------------
# Serveur HTTP
# --------------------------------------------------------------------------
def check_name(name):
    name = urllib.parse.unquote(name)
    if not NAME_RE.match(name):
        raise ValueError("nom invalide (lettres, chiffres, _ . -, 64 max)")
    return name


def fetch(url):
    if not url.startswith(("http://", "https://")):
        raise ValueError("URL http(s) uniquement")
    req = urllib.request.Request(url, headers={"User-Agent": "ccimg/1"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = resp.read(MAX_BODY + 1)
    if len(data) > MAX_BODY:
        raise ValueError("image trop grosse")
    return data


def clamp_int(value, default, lo, hi):
    try:
        return max(lo, min(hi, int(value)))
    except (TypeError, ValueError):
        return default


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, token, root):
        super().__init__(addr, Handler)
        self.token = token
        self.img_dir = os.path.join(root, "images")
        self.cci_dir = os.path.join(root, "cci")
        os.makedirs(self.img_dir, exist_ok=True)
        os.makedirs(self.cci_dir, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "ccimg/1"

    def reply(self, status, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def parse(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        return u.path, q

    def authorized(self, q):
        if self.server.token and q.get("k") != self.server.token:
            self.reply(403, "token invalide\n")
            return False
        return True

    def read_body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n <= 0 or n > MAX_BODY:
            raise ValueError("corps vide ou trop gros")
        return self.rfile.read(n)

    def do_GET(self):
        path, q = self.parse()
        if path == "/ccimg.lua":
            lua = os.path.join(HERE, "ccimg.lua")
            if os.path.exists(lua):
                with open(lua, "rb") as f:
                    return self.reply(200, f.read())
            return self.reply(404, "ccimg.lua absent à côté du serveur\n")
        if not self.authorized(q):
            return
        try:
            if path in ("/", "/help"):
                self.reply(200, __doc__)
            elif path == "/list":
                out = [f"img {n}" for n in sorted(os.listdir(self.server.img_dir))]
                out += [f"cci {n}" for n in sorted(os.listdir(self.server.cci_dir))]
                self.reply(200, "\n".join(out) + "\n")
            elif path == "/convert":
                self.reply(200, self.convert(q))
            elif path.startswith("/cci/"):
                with open(os.path.join(self.server.cci_dir, check_name(path[5:])), "rb") as f:
                    self.reply(200, f.read())
            elif path.startswith("/preview/"):
                with open(os.path.join(self.server.cci_dir, check_name(path[9:])), encoding="ascii") as f:
                    img = render_cci(f.read(), clamp_int(q.get("scale"), 4, 1, 16))
                buf = io.BytesIO()
                img.save(buf, "PNG")
                self.reply(200, buf.getvalue(), "image/png")
            else:
                self.reply(404, "route inconnue\n")
        except FileNotFoundError:
            self.reply(404, "fichier introuvable\n")
        except Exception as e:  # noqa: BLE001
            self.reply(400, f"erreur: {e}\n")

    def do_POST(self):
        path, q = self.parse()
        if not self.authorized(q):
            return
        try:
            data = self.read_body()
            if path == "/upload":
                name = check_name(q.get("name", ""))
                load_image(data)                       # vérifie que c'est une image
                with open(os.path.join(self.server.img_dir, name), "wb") as f:
                    f.write(data)
                self.reply(200, "ok\n")
            elif path.startswith("/cci/"):
                name = check_name(path[5:])
                text = data.decode("ascii")
                parse_cci(text)                        # vérifie le format
                with open(os.path.join(self.server.cci_dir, name), "w", encoding="ascii") as f:
                    f.write(text)
                self.reply(200, "ok\n")
            else:
                self.reply(404, "route inconnue\n")
        except Exception as e:  # noqa: BLE001
            self.reply(400, f"erreur: {e}\n")

    def convert(self, q):
        w = clamp_int(q.get("w"), 51, 1, MAX_W)
        h = clamp_int(q.get("h"), 19, 1, MAX_H)
        if "url" in q:
            data = fetch(q["url"])
        elif "name" in q:
            with open(os.path.join(self.server.img_dir, check_name(q["name"])), "rb") as f:
                data = f.read()
        else:
            raise ValueError("paramètre name ou url requis")
        text = image_to_cci(load_image(data), w, h, cc_palette=q.get("cc") == "1")
        if "save" in q:
            with open(os.path.join(self.server.cci_dir, check_name(q["save"])), "w", encoding="ascii") as f:
                f.write(text)
        return text


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="image <-> texte subpixel CC:Tweaked")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="lance le serveur HTTP")
    s.add_argument("--host", default="0.0.0.0")
    s.add_argument("--port", type=int, default=8888)
    s.add_argument("--token", default="", help="secret exigé dans ?k=")
    s.add_argument("--dir", default=os.path.join(HERE, "data"))

    c = sub.add_parser("convert", help="image -> fichier .cci")
    c.add_argument("image")
    c.add_argument("out")
    c.add_argument("-W", "--width", type=int, default=51)
    c.add_argument("-H", "--height", type=int, default=19)
    c.add_argument("--cc", action="store_true", help="palette CC par défaut")

    r = sub.add_parser("render", help="fichier .cci -> PNG")
    r.add_argument("cci")
    r.add_argument("out")
    r.add_argument("--scale", type=int, default=4)

    args = ap.parse_args()
    if args.cmd == "serve":
        if not args.token:
            print("Attention : aucun --token, le port est ouvert à tout le monde.", file=sys.stderr)
        srv = Server((args.host, args.port), args.token, args.dir)
        print(f"ccimg écoute sur {args.host}:{args.port} (données : {args.dir})")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass
    elif args.cmd == "convert":
        with open(args.image, "rb") as f:
            text = image_to_cci(load_image(f.read()), args.width, args.height, args.cc)
        with open(args.out, "w", encoding="ascii") as f:
            f.write(text)
        print("ok :", args.out)
    elif args.cmd == "render":
        with open(args.cci, encoding="ascii") as f:
            render_cci(f.read(), args.scale).save(args.out)
        print("ok :", args.out)


if __name__ == "__main__":
    main()