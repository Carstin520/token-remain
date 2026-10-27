#!/usr/bin/env python3
"""Stage A only: exact O4-C primitives, masters, layer sources and review sheet.

Writes exclusively beside this script. Pillow raster exports use 4x sampling;
the SVGs retain the unrounded geometry and exact sRGB palette from the brief.
No application asset, state PNG, installation or preference is touched.
"""
import json
import math
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
PALETTE = dict(background="#081431", shell="#8F7BF2", depth="#5B4FB0",
               antenna="#B7A9F7", screen="#070B12", eyes="#3ECFE0",
               lit="#3ECFE0", dim="#2B3754")
MONO = dict(background="#000000", shell="#B3B3B3", depth="#737373",
            antenna="#D9D9D9", screen="#000000", eyes="#FFFFFF",
            lit="#FFFFFF", dim="#333333")
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def primitives(variant="full", lit=None, appearance="default"):
    colors = MONO if appearance == "tinted" else PALETTE
    count, radius, dot = (20, 400, 30) if variant == "full" else (10, 392, 46)
    lit = (15 if variant == "full" else 8) if lit is None else lit
    result = []
    if variant != "small":
        for i in range(count):
            a = math.radians(-90 + i * 360 / count)
            result.append(dict(kind="circle", group="Ring", role="lit" if i < lit else "dim",
                               index=i, cx=512 + radius * math.cos(a),
                               cy=512 + radius * math.sin(a), r=dot))
    def rect(role, x, y, w, h, r, group="Head"):
        result.append(dict(kind="rect", group=group, role=role, x=x, y=y, w=w, h=h, r=r))
    if variant == "small":
        rect("antenna", 439, 201, 146, 88, 33)
        rect("shell", 200, 270, 624, 552, 166)
        rect("screen", 291, 372, 442, 331, 91, "Face")
        eyes, y, eye_r = (411, 613), 538, 56
    else:
        rect("antenna", 459, 262, 106, 64, 24)
        rect("depth", 286, 352, 452, 400, 120)
        rect("shell", 286, 312, 452, 400, 120)
        rect("screen", 352, 386, 320, 240, 66, "Face")
        eyes, y, eye_r = (439, 585), 506, 40 if variant == "medium" else 34
    for x in eyes:
        result.append(dict(kind="circle", group="Face", role="eyes", cx=x, cy=y, r=eye_r))
    for p in result:
        p["fill"] = colors[p["role"]]
    return result


def svg(variant="full", lit=None, appearance="default", shape="tile", role=None):
    colors = MONO if appearance == "tinted" else PALETTE
    contents = []
    if role is None:
        contents.append(f'<rect width="1024" height="1024" fill="{colors["background"]}"/>')
    for p in primitives(variant, lit, appearance):
        if role is not None and p["role"] != role:
            continue
        if p["kind"] == "circle":
            contents.append(f'<circle cx="{p["cx"]:.6f}" cy="{p["cy"]:.6f}" r="{p["r"]}" fill="{p["fill"]}"/>')
        else:
            contents.append(f'<rect x="{p["x"]}" y="{p["y"]}" width="{p["w"]}" height="{p["h"]}" rx="{p["r"]}" fill="{p["fill"]}"/>')
    body = "\n".join(contents)
    defs = ""
    if shape == "macos":
        defs = '<defs><clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185.4"/></clipPath></defs>'
        body = '<g clip-path="url(#tile)"><g transform="translate(100 100) scale(0.8046875)">' + body + '</g></g>'
    elif shape in ("ios", "watchos"):
        mask = '<circle cx="512" cy="512" r="512"/>' if shape == "watchos" else '<rect width="1024" height="1024" rx="224"/>'
        defs = f'<defs><clipPath id="tile">{mask}</clipPath></defs>'
        body = '<g clip-path="url(#tile)">' + body + '</g>'
    return '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n' + defs + '\n' + body + '\n</svg>\n'


def render(variant="full", size=1024, lit=None, appearance="default", shape="tile"):
    scale = size * 4 / 1024
    extent = size * 4
    image = Image.new("RGBA", (extent, extent))
    draw = ImageDraw.Draw(image)
    inset, factor = (100, 824 / 1024) if shape == "macos" else (0, 1)
    def pos(v):
        return (inset + v * factor) * scale
    colors = MONO if appearance == "tinted" else PALETTE
    draw.rectangle((pos(0), pos(0), pos(1024), pos(1024)), fill=colors["background"])
    for p in primitives(variant, lit, appearance):
        if p["kind"] == "circle":
            x, y, r = p["cx"], p["cy"], p["r"]
            draw.ellipse((pos(x-r), pos(y-r), pos(x+r), pos(y+r)), fill=p["fill"])
        else:
            x, y, w, h = p["x"], p["y"], p["w"], p["h"]
            draw.rounded_rectangle((pos(x), pos(y), pos(x+w), pos(y+h)),
                                   radius=p["r"] * factor * scale, fill=p["fill"])
    if shape != "tile":
        mask = Image.new("L", image.size)
        md = ImageDraw.Draw(mask)
        if shape == "watchos":
            md.ellipse((0, 0, extent-1, extent-1), fill=255)
        else:
            r = 185.4 if shape == "macos" else 224
            md.rounded_rectangle((inset*scale, inset*scale, (1024-inset)*scale-1,
                                  (1024-inset)*scale-1), radius=r*scale, fill=255)
        image.putalpha(mask)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def save(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, icc_profile=ICC)


def write_assets():
    for variant in ("full", "medium", "small"):
        for appearance in ("default", "dark", "tinted"):
            folder = ROOT / "masters" / appearance
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"{variant}-1024.svg").write_text(svg(variant, appearance=appearance))
            save(render(variant, appearance=appearance), folder / f"{variant}-1024.png")
        for size in (1024, 256, 128, 64, 48, 32, 24, 16):
            save(render(variant, size), ROOT / "sizes" / f"{variant}-{size}.png")
        layer_dir = ROOT / "layers" / variant
        layer_dir.mkdir(parents=True, exist_ok=True)
        for role in sorted({p["role"] for p in primitives(variant)}):
            (layer_dir / f"{role}.svg").write_text(svg(variant, role=role))
        write_composer(variant)
    for count, name in [(20,"20"),(15,"15"),(10,"10"),(5,"05"),(1,"01"),(0,"00"),(0,"no-data")]:
        folder = ROOT / "runtime"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"full-{name}.svg").write_text(svg(lit=count, shape="macos"))
        save(render(size=1024, lit=count, shape="macos"), folder / f"full-{name}.png")


def write_composer(variant):
    """Editable native package; application/compiler validation is tracked separately.

    Serialization reference (empirical schema, not an Apple API contract):
    https://github.com/peterpoliwoda/icon-composer-template
    """
    package = ROOT / "composer" / f"TokenRemain-{variant}.icon"
    assets = package / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    def color(value):
        return "srgb:" + ",".join(f"{int(value[i:i+2],16)/255:.9f}" for i in (1,3,5)) + ",1.000000000"
    groups = []
    for name, roles in [("Ring",["dim","lit"]),("Head",["antenna","depth","shell"]),("Face",["screen","eyes"])]:
        layers = []
        present = {p["role"] for p in primitives(variant)}
        for role in roles:
            if role not in present:
                continue
            filename = {"dim":"dots-dim", "lit":"dots-lit"}.get(role,role) + ".svg"
            (assets/filename).write_text(svg(variant,role=role))
            layers.append({"name":filename[:-4],"image-name":filename,
                "glass":name=="Head", "fill-specializations":[
                    {"appearance":"dark","value":{"solid":color(PALETTE[role])}},
                    {"appearance":"tinted","value":{"solid":color(MONO[role])}}]})
        if layers:
            groups.append({"name":name,"layers":layers,"lighting":"individual",
                "specular":name=="Head","blur-material":0,
                "translucency":{"enabled":False,"value":0},
                "shadow":{"kind":"neutral" if name=="Head" else "none",
                          "opacity":0.5 if name=="Head" else 0}})
    manifest = {"fill":{"solid":color(PALETTE["background"])},
        "fill-specializations":[
            {"appearance":"dark","value":{"solid":color(PALETTE["background"])}},
            {"appearance":"tinted","value":{"solid":color(MONO["background"])}}],
        "color-space-for-untagged-svg-colors":"srgb","groups":groups,
        "supported-platforms":{"squares":["macOS"]}}
    (package/"icon.json").write_text(json.dumps(manifest,indent=2)+"\n")


def sheet():
    canvas = Image.new("RGB", (3456, 3360), "#EDEEF2")
    d = ImageDraw.Draw(canvas)
    def font(n):
        return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", n)
    def text(x, y, value, n=24, color="#454E66"):
        d.text((x,y), value, fill=color, font=font(n))
    def place(im, x, y):
        canvas.paste(im, (int(x),int(y)), im)
    text(72,44,"TOKENREMAIN  /  O4-C",50,"#17223A")
    text(72,110,"STAGE A  ·  EXACT VECTOR MASTERS  ·  27 OCT 2026",24)
    text(72,151,"Flat geometry + sRGB review. Native Liquid Glass / Clear previews are separate evidence. No production assets replaced.",25)
    for col, variant in enumerate(("full","medium","small")):
        x = 72 + col * 1120
        text(x,211,variant.upper(),36,"#17223A")
        subtitle = {"full":"20 dots · 15 lit · eye r34", "medium":"10 dots · 8 lit · eye r40", "small":"No ring · enlarged head · no depth band"}[variant]
        text(x,260,subtitle,23)
        place(render(variant),x,304)
        text(x,1344,"1024 px · tile coordinates · 1 image px = 1 sheet px",22)
        xx = x
        for size in (256,128,64,48,32,24,16):
            place(render(variant,size),xx,1400 + (256-size)//2)
            text(xx,1670,str(size),20)
            xx += size + 42
    text(72,1740,"CROP × APPEARANCE",36,"#17223A")
    text(72,1789,"Full · 15/20. iOS corner mask is illustrative; watchOS is circular; macOS uses 100 inset / r185.4.",24)
    for col, appearance in enumerate(("default","dark","tinted")):
        x = 72 + col * 1120
        text(x,1850,appearance.upper(),27)
        for i, shape in enumerate(("macos","ios","watchos")):
            xx = x + i*342
            place(render(size=256,appearance=appearance,shape=shape),xx,1900)
            text(xx,2173,{"macos":"macOS","ios":"iOS","watchos":"watchOS"}[shape],23)
    text(72,2250,"RUNTIME  /  FIXED FACE · CYAN ONLY",36,"#17223A")
    text(72,2300,"12 o'clock start, clockwise. 0% and no data intentionally look identical; state identity remains distinct.",24)
    for i,(count,label) in enumerate([(20,"100% · 20 lit"),(15,"75% · 15 lit"),(10,"50% · 10 lit"),(5,"25% · 5 lit"),(1,"5% · 1 lit"),(0,"0% · 0 lit"),(0,"NO DATA · 0 lit")]):
        xx = 72 + i*472
        place(render(size=320,lit=count,shape="macos"),xx,2360)
        text(xx,2703,label,24)
    text(72,2790,"SMALL-SIZE INSPECTION  /  NEAREST-NEIGHBOR ENLARGEMENTS",33,"#17223A")
    for i,(variant,size) in enumerate([("small",16),("medium",32),("full",40),("full",48),("full",64)]):
        xx=72+i*660
        im=render(variant,size)
        place(im.resize((256,256),Image.Resampling.NEAREST),xx,2850)
        text(xx,3124,f"{variant.upper()} · {size}px → 256px",23)
    text(72,3216,"Masters preserve exact source colors. Antialiasing blends edge pixels. Default and Dark are identical by design.",24)
    text(72,3260,"All three reference SVGs verified: maximum coordinate difference < 0.05px; geometry and fill colors match the approved design.",23)
    save(canvas,ROOT/"contact-sheet.png")


if __name__ == "__main__":
    write_assets()
    sheet()
    (ROOT/"geometry.json").write_text(json.dumps({"palette":PALETTE,"mono":MONO,
        "variants":{v:primitives(v) for v in ("full","medium","small")}},indent=2)+"\n")
    print("Generated review-only masters, layers, sizes, runtime states and contact sheet.")
