# SCI Landing Pages

One client = one folder in `sites/clients/<client-name>/` with a `client.json` (their details + your copy)
and any images. One command turns it into a finished website in `sites/out/<client-name>/`.

## Workflow for a new client
1. **Intake call** using `sites/INTAKE.md` (about 20–30 minutes).
2. **Write the copy** (that's the part you're selling).
3. **Fill in the form**: copy `sites/clients/demo-saltmarsh-pools/client.json` to a new folder and replace the text.
   Put their logo/photos in the same folder and reference them by file name (`"logo": "logo.png"`).
   Leave out any section you don't need (testimonials, gallery, FAQ, about, highlights are all optional).
4. **Build**: `python3 sites/build_site.py sites/clients/<client-name>/client.json`
   (or ask Claude to do steps 3–4 from your notes).
5. **Review together** with the client, make edits, rebuild.
6. **Publish** (below) and connect their domain.

Rules baked into the template: client text is escaped (can't break the page); button and link colors are
adjusted automatically so they stay readable on any brand color; it works on phones; it includes basic
search-engine information (title, description, business details).

**Only use real testimonials** the client gives you, with their permission.

## Publishing on Cloudflare Pages (free)
Recommended: create the Cloudflare account **in the client's name** (or add them as a member) so they own it.
1. Cloudflare dashboard → **Workers & Pages** → **Create** → **Pages** → **Upload assets**.
2. Name the project after the business, drag in the contents of `sites/out/<client-name>/`, **Deploy**.
3. **Custom domains** → add their domain → follow Cloudflare's DNS instructions at their registrar.
   Never delete their email (MX/TXT) records.
4. Updates: rebuild, then **Create new deployment** and upload again.

## Care plan ($29/month): what's included
- Hosting and the security certificate (free on Cloudflare; your fee covers your time and responsibility)
- Up to 30 minutes of small text/photo edits per month
- A quick check each month that the site loads and links/phone/email work
Bigger changes (new sections, rewrites) are quoted separately at your rates.
