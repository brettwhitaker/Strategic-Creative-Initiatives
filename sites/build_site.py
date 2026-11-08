#!/usr/bin/env python3
"""SCI landing-page builder.

Turns one client file (sites/clients/<slug>/client.json) into a finished one-page website in
sites/out/<slug>/ (index.html + assets), ready to upload to Cloudflare Pages.

    python3 sites/build_site.py sites/clients/<slug>/client.json

Every section except the header, hero and contact is optional: leave it out of client.json and it
simply isn't shown. All client text is HTML-escaped, so copy can contain any characters.
"""
import html, json, pathlib, re, shutil, sys

FONTS = {  # (heading, body, Google Fonts query)
    "modern":   ("Montserrat", "Inter", "family=Montserrat:wght@600;700&family=Inter:wght@400;500;600"),
    "classic":  ("Fraunces", "Inter", "family=Fraunces:opsz,wght@9..144,600&family=Inter:wght@400;500;600"),
    "friendly": ("Nunito", "Nunito", "family=Nunito:wght@400;600;800"),
}

def e(s):  # escape client text
    return html.escape(str(s or ""), quote=True)

# ---------- color helpers (keep text readable whatever brand colors the client has) ----------
def _rgb(h):
    h = h.lstrip("#"); h = "".join(c * 2 for c in h) if len(h) == 3 else h
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
def _hex(rgb):
    return "#" + "".join(f"{max(0, min(255, round(c * 255))):02x}" for c in rgb)
def _lum(h):
    return sum(w * (c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4) for w, c in zip((0.2126, 0.7152, 0.0722), _rgb(h)))
def contrast(a, b):
    la, lb = sorted((_lum(a), _lum(b)), reverse=True); return (la + 0.05) / (lb + 0.05)
def readable_on(bg):
    return "#ffffff" if contrast("#ffffff", bg) >= contrast("#111418", bg) else "#111418"
def darken_until(color, bg, target=4.5):
    rgb = _rgb(color)
    for _ in range(40):
        if contrast(_hex(rgb), bg) >= target: break
        rgb = tuple(c * 0.92 for c in rgb)
    return _hex(rgb)

def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")

def build(client_file):
    client_file = pathlib.Path(client_file).resolve()
    c = json.loads(client_file.read_text())
    src_dir = client_file.parent
    slug = c.get("slug") or slugify(c["business_name"])
    out = pathlib.Path(__file__).resolve().parent / "out" / slug
    if out.exists(): shutil.rmtree(out)
    (out / "assets").mkdir(parents=True)

    def asset(path):  # copy a client asset and return its published path
        if not path: return None
        p = (src_dir / path).resolve()
        if not p.is_file(): sys.exit(f"Missing asset: {p}")
        shutil.copy2(p, out / "assets" / p.name); return f"assets/{p.name}"

    col = c.get("colors", {})
    bg = col.get("background", "#fbfbfa")
    primary = col.get("primary", "#1f3a5f")
    accent = col.get("accent", primary)
    on_primary = readable_on(primary)
    link = darken_until(primary, bg)
    eyebrow = darken_until(accent, bg)
    head_font, body_font, gq = FONTS.get(c.get("font", "modern"), FONTS["modern"])

    ct = c.get("contact", {})
    phone, email = ct.get("phone"), ct.get("email")
    tel = "tel:+1" + re.sub(r"\D", "", phone)[-10:] if phone else None
    cta_link = c.get("cta_link") or tel or (f"mailto:{email}" if email else "#contact")
    logo = asset(c.get("logo")); hero_img = asset(c.get("hero_image"))
    seo = c.get("seo", {})
    title = seo.get("title") or f'{c["business_name"]} | {c.get("tagline", "")}'.strip(" |")
    desc = seo.get("description") or c.get("intro", "")[:160]
    domain = c.get("domain")
    nav = []

    S = []  # sections
    # ----- services
    sv = c.get("services")
    if sv:
        nav.append(("services", "Services"))
        items = "".join(
            f'<div class="card"><h3>{e(i["name"])}</h3><p>{e(i.get("description"))}</p>'
            + (f'<div class="price">{e(i["price"])}</div>' if i.get("price") else "") + "</div>"
            for i in sv["items"])
        S.append(f'''<section id="services"><div class="wrap">
  <div class="eyebrow">{e(sv.get("eyebrow", "What we do"))}</div><h2>{e(sv.get("title", "Services"))}</h2>
  {f'<p class="muted lead2">{e(sv["intro"])}</p>' if sv.get("intro") else ""}
  <div class="grid">{items}</div>
  {f'<p class="muted note">{e(sv["note"])}</p>' if sv.get("note") else ""}
</div></section>''')
    # ----- highlights / why us
    hl = c.get("highlights")
    if hl:
        items = "".join(f'<div class="hl"><h3>{e(h["title"])}</h3><p>{e(h["text"])}</p></div>' for h in hl["items"])
        S.append(f'''<section class="tint"><div class="wrap">
  <div class="eyebrow">{e(hl.get("eyebrow", "Why choose us"))}</div><h2>{e(hl.get("title", "Why customers choose us"))}</h2>
  <div class="grid">{items}</div></div></section>''')
    # ----- about
    ab = c.get("about")
    if ab:
        nav.append(("about", "About"))
        img = asset(ab.get("image"))
        paras = "".join(f"<p>{e(p)}</p>" for p in ab.get("text", []))
        S.append(f'''<section id="about"><div class="wrap {"about-grid" if img else ""}">
  {f'<img class="about-img" src="{img}" alt="{e(ab.get("image_alt", c["business_name"]))}" loading="lazy">' if img else ""}
  <div><div class="eyebrow">{e(ab.get("eyebrow", "About us"))}</div><h2>{e(ab.get("title", "About " + c["business_name"]))}</h2>{paras}</div>
</div></section>''')
    # ----- gallery
    ga = c.get("gallery")
    if ga:
        imgs = "".join(f'<img src="{asset(g["src"])}" alt="{e(g.get("alt"))}" loading="lazy">' for g in ga["images"])
        S.append(f'''<section class="tint"><div class="wrap"><div class="eyebrow">{e(ga.get("eyebrow", "Our work"))}</div>
  <h2>{e(ga.get("title", "Recent work"))}</h2><div class="gallery">{imgs}</div></div></section>''')
    # ----- testimonials (only real ones the client provided)
    te = c.get("testimonials")
    if te:
        nav.append(("reviews", "Reviews"))
        items = "".join(f'<figure class="card quote"><blockquote>"{e(t["quote"])}"</blockquote><figcaption>{e(t.get("name"))}</figcaption></figure>' for t in te["items"])
        S.append(f'''<section id="reviews"><div class="wrap"><div class="eyebrow">{e(te.get("eyebrow", "Reviews"))}</div>
  <h2>{e(te.get("title", "What customers say"))}</h2><div class="grid">{items}</div></div></section>''')
    # ----- FAQ
    fq = c.get("faq")
    if fq:
        items = "".join(f'<details><summary>{e(q["q"])}</summary><p>{e(q["a"])}</p></details>' for q in fq["items"])
        S.append(f'''<section class="tint"><div class="wrap narrow"><div class="eyebrow">FAQ</div>
  <h2>{e(fq.get("title", "Common questions"))}</h2>{items}</div></section>''')
    # ----- contact (always)
    nav.append(("contact", "Contact"))
    lines = []
    if phone: lines.append(f'<p><strong>Call or text:</strong> <a href="{tel}">{e(phone)}</a></p>')
    if email: lines.append(f'<p><strong>Email:</strong> <a href="mailto:{e(email)}">{e(email)}</a></p>')
    if ct.get("address"): lines.append(f'<p><strong>Address:</strong> {e(ct["address"])}'
                                       + (f' · <a href="{e(ct["map_link"])}" target="_blank" rel="noopener">Directions</a>' if ct.get("map_link") else "") + "</p>")
    if ct.get("service_area"): lines.append(f'<p><strong>Serving:</strong> {e(ct["service_area"])}</p>')
    if ct.get("hours"): lines.append("<p><strong>Hours:</strong><br>" + "<br>".join(e(h) for h in ct["hours"]) + "</p>")
    socials = [(k.title(), ct[k]) for k in ("facebook", "instagram", "linkedin", "tiktok", "youtube") if ct.get(k)]
    if socials: lines.append("<p>" + " · ".join(f'<a href="{e(u)}" target="_blank" rel="noopener">{n}</a>' for n, u in socials) + "</p>")
    S.append(f'''<section id="contact" class="contact"><div class="wrap narrow">
  <div class="eyebrow">{e(ct.get("eyebrow", "Get in touch"))}</div><h2>{e(ct.get("title", "Let's talk"))}</h2>
  {f'<p class="muted">{e(ct["intro"])}</p>' if ct.get("intro") else ""}
  <div class="contact-box">{"".join(lines)}<p style="margin-top:20px"><a class="btn" href="{e(cta_link)}">{e(c.get("cta_text", "Contact us"))}</a></p></div>
</div></section>''')

    nav_html = "".join(f'<a href="#{i}">{n}</a>' for i, n in nav)
    brand = f'<img src="{logo}" alt="{e(c["business_name"])}">' if logo else f'<span>{e(c["business_name"])}</span>'
    hero_side = f'<div class="hero-img"><img src="{hero_img}" alt="{e(c.get("hero_image_alt", c["business_name"]))}"></div>' if hero_img else ""
    ld = {"@context": "https://schema.org", "@type": c.get("schema_type", "LocalBusiness"), "name": c["business_name"],
          "description": desc}
    if domain: ld["url"] = f"https://{domain}/"
    if phone: ld["telephone"] = phone
    if email: ld["email"] = email
    if ct.get("address"): ld["address"] = ct["address"]
    if ct.get("service_area"): ld["areaServed"] = ct["service_area"]

    page = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
{f'<link rel="canonical" href="https://{e(domain)}/">' if domain else ""}
<meta property="og:title" content="{e(title)}">
<meta property="og:description" content="{e(desc)}">
{f'<link rel="icon" href="{logo}">' if logo else ""}
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?{gq}&display=swap" rel="stylesheet">
<script type="application/ld+json">{json.dumps(ld)}</script>
<style>
:root {{ --bg: {bg}; --primary: {primary}; --on-primary: {on_primary}; --link: {link}; --eyebrow: {eyebrow};
        --ink: #16181d; --muted: #4b5260; --line: rgba(0,0,0,.09); --card: #fff; --tint: rgba(0,0,0,.025); }}
* {{ box-sizing: border-box; }} html {{ scroll-behavior: smooth; }}
@media (prefers-reduced-motion: reduce) {{ html {{ scroll-behavior: auto; }} }}
body {{ margin: 0; background: var(--bg); color: var(--ink); font: 400 17px/1.65 "{body_font}", system-ui, sans-serif; }}
h1, h2, h3 {{ font-family: "{head_font}", "{body_font}", sans-serif; line-height: 1.15; margin: 0 0 .5em; }}
h1 {{ font-size: clamp(2rem, 4.6vw, 3.1rem); }} h2 {{ font-size: clamp(1.6rem, 3.2vw, 2.2rem); }} h3 {{ font-size: 1.15rem; }}
p {{ margin: 0 0 1em; }} a {{ color: var(--link); text-underline-offset: 3px; }}
a:focus-visible, .btn:focus-visible, summary:focus-visible {{ outline: 3px solid var(--link); outline-offset: 3px; }}
.wrap {{ max-width: 1080px; margin: 0 auto; padding: 0 20px; }} .narrow {{ max-width: 760px; }}
.eyebrow {{ text-transform: uppercase; letter-spacing: .12em; font-size: .78rem; font-weight: 700; color: var(--eyebrow); margin-bottom: .7rem; }}
.muted {{ color: var(--muted); }}
header {{ position: sticky; top: 0; z-index: 9; background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(8px); border-bottom: 1px solid var(--line); }}
header .wrap {{ display: flex; justify-content: space-between; align-items: center; min-height: 64px; gap: 14px; }}
.brand {{ text-decoration: none; color: var(--ink); font-family: "{head_font}", sans-serif; font-weight: 700; font-size: 1.1rem; display: flex; align-items: center; }}
.brand img {{ height: 44px; width: auto; display: block; }}
nav a {{ margin-left: 20px; color: var(--muted); text-decoration: none; font-weight: 600; font-size: .95rem; }}
@media (max-width: 720px) {{ nav a:not(:last-child) {{ display: none; }} }}
.btn {{ display: inline-block; max-width: 100%; overflow-wrap: anywhere; background: var(--primary); color: var(--on-primary); padding: 13px 24px; border-radius: 999px; font-weight: 700; text-decoration: none; }}
.btn:hover {{ filter: brightness(1.08); }}
section {{ padding: 76px 0; }} @media (max-width: 720px) {{ section {{ padding: 56px 0; }} }}
.tint {{ background: var(--tint); border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }}
.hero {{ padding: 72px 0; }}
.hero-grid {{ display: grid; grid-template-columns: {"1.2fr .8fr" if hero_img else "1fr"}; gap: 48px; align-items: center; }}
.hero .lead {{ font-size: 1.2rem; color: var(--muted); max-width: 36em; }}
.hero-img img {{ width: 100%; height: auto; border-radius: 18px; display: block; box-shadow: 0 18px 44px rgba(0,0,0,.15); }}
@media (max-width: 860px) {{ .hero-grid {{ grid-template-columns: 1fr; }} }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 20px; margin-top: 28px; }}
.card, .hl {{ background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 24px; }}
.card p, .hl p {{ color: var(--muted); margin: 0; }}
.price {{ margin-top: 12px; font-weight: 700; color: var(--link); }}
.note {{ margin-top: 20px; font-size: .95rem; }} .lead2 {{ max-width: 40em; }}
.about-grid {{ display: grid; grid-template-columns: 300px 1fr; gap: 44px; align-items: start; }}
.about-img {{ width: 100%; height: auto; border-radius: 16px; display: block; }}
@media (max-width: 760px) {{ .about-grid {{ grid-template-columns: 1fr; }} .about-img {{ max-width: 280px; }} }}
.gallery {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; margin-top: 26px; }}
.gallery img {{ width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 12px; display: block; }}
.quote blockquote {{ margin: 0 0 12px; font-style: italic; }} .quote figcaption {{ font-weight: 700; color: var(--muted); }}
details {{ background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px 20px; margin-top: 12px; }}
summary {{ cursor: pointer; font-weight: 700; }} details p {{ margin: 10px 0 0; color: var(--muted); }}
.contact {{ text-align: center; }} .contact-box {{ background: var(--card); border: 1px solid var(--line); border-radius: 18px; padding: 32px 22px; margin-top: 22px; }}
footer {{ border-top: 1px solid var(--line); padding: 28px 0 40px; color: var(--muted); font-size: .9rem; }}
footer .wrap {{ display: flex; justify-content: space-between; flex-wrap: wrap; gap: 8px; }}
</style>
</head>
<body>
<header><div class="wrap"><a class="brand" href="#top">{brand}</a><nav aria-label="Main">{nav_html}</nav></div></header>
<main id="top">
<section class="hero"><div class="wrap hero-grid"><div>
  {f'<div class="eyebrow">{e(c["eyebrow"])}</div>' if c.get("eyebrow") else ""}
  <h1>{e(c.get("headline", c["business_name"]))}</h1>
  <p class="lead">{e(c.get("intro"))}</p>
  <a class="btn" href="{e(cta_link)}">{e(c.get("cta_text", "Contact us"))}</a>
</div>{hero_side}</div></section>
{"".join(S)}
</main>
<footer><div class="wrap"><span>© {e(c.get("year", 2026))} {e(c.get("legal_name", c["business_name"]))}</span>
<span>{e(c.get("tagline", ""))}</span></div></footer>
</body>
</html>
'''
    (out / "index.html").write_text(page)
    if domain: (out / "CNAME").write_text(domain + "\n")
    print(f"Built {out}/index.html  (button text on brand color: {on_primary}; link color: {link})")
    return out

if __name__ == "__main__":
    if len(sys.argv) != 2: sys.exit(__doc__)
    build(sys.argv[1])
