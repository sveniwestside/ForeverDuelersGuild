# World of Warcraft class artwork

The nine class icons used by the local website are original Blizzard game
artwork downloaded from Blizzard's `render.worldofwarcraft.com` image CDN on
2026-10-04. Every source returned HTTP 200 with `image/jpeg`; every decoded image
is 56 × 56 pixels. All nine images were visually inspected against their class
labels before being added.

| Class | Website asset | Verified Blizzard source |
| --- | --- | --- |
| Warrior | `web/public/assets/classes/warrior.png` | [classicon_warrior.jpg](https://render.worldofwarcraft.com/icons/56/classicon_warrior.jpg) |
| Paladin | `web/public/assets/classes/paladin.png` | [classicon_paladin.jpg](https://render.worldofwarcraft.com/icons/56/classicon_paladin.jpg) |
| Hunter | `web/public/assets/classes/hunter.png` | [classicon_hunter.jpg](https://render.worldofwarcraft.com/icons/56/classicon_hunter.jpg) |
| Rogue | `web/public/assets/classes/rogue.png` | [classicon_rogue.jpg](https://render.worldofwarcraft.com/icons/56/classicon_rogue.jpg) |
| Priest | `web/public/assets/classes/priest.png` | [classicon_priest.jpg](https://render.worldofwarcraft.com/icons/56/classicon_priest.jpg) |
| Shaman | `web/public/assets/classes/shaman.png` | [classicon_shaman.jpg](https://render.worldofwarcraft.com/icons/56/classicon_shaman.jpg) |
| Mage | `web/public/assets/classes/mage.png` | [classicon_mage.jpg](https://render.worldofwarcraft.com/icons/56/classicon_mage.jpg) |
| Warlock | `web/public/assets/classes/warlock.png` | [classicon_warlock.jpg](https://render.worldofwarcraft.com/icons/56/classicon_warlock.jpg) |
| Druid | `web/public/assets/classes/druid.png` | [classicon_druid.jpg](https://render.worldofwarcraft.com/icons/56/classicon_druid.jpg) |

## Conversion and integrity

The source JPEGs were decoded as RGB and saved as PNG, with no resizing,
cropping, recoloring, retouching, or generated additions. Each converted PNG was
reopened and its decoded RGB pixels compared byte for byte with its source.
The manifest at `web/public/assets/classes/manifest.json` records the source URL,
retrieval timestamp, dimensions, SHA-256 of the original JPEG response, and
SHA-256 of the resulting PNG for each icon.

`python tools/export-class-icons.py` refreshes this fixed set of nine assets from
the same official URLs. This development tool uses Pillow, which was already
installed when the assets were imported; the local backend and website do not
need Pillow or external image requests. No files in the installed game or addon
release were changed.

## Attribution

World of Warcraft artwork © Blizzard Entertainment, Inc. World of Warcraft and
Blizzard Entertainment are trademarks or registered trademarks of Blizzard
Entertainment, Inc. The class artwork remains Blizzard-owned and is excluded
from this repository's software license. This independent fan project does not
claim ownership of the artwork, Blizzard endorsement, or an additional artwork
license. The website should retain a visible Blizzard artwork credit.
