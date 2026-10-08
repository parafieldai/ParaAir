# ParaAir product icon

Last updated: 2026-10-09

The current product mark is **Glide**, an abstract folded flight shape with no letter. Two polygons form the mark, set inside a square badge with small corner cuts. It uses only three flat sRGB fills: charcoal `#20282C`, warm white `#F1EFE7`, and muted green `#9AC7B4`. There are no curves, gradients, highlights, shadows, or strokes. This revision uses no image generation.

The user confirmed Glide on October 9. The signed filesystem fix retains it; the installed application PNG, ICNS and default drive PNG match these source assets byte for byte. The later alternatives remain provenance only. Finder now displays a working system drive icon; the custom/default artwork has not been verified as the native volume's sidebar icon.

`App/BrandIconGeometry.swift` is the geometry and palette source. `scripts/render-brand.swift` exports the SVG and PNG assets; `scripts/build-icons.sh` compiles the renderer and builds all ICNS sizes directly from the geometry. Raster exports disable antialiasing to retain exactly three opaque RGB values and fully transparent outside pixels. macOS may interpolate pixels when displaying an icon at other sizes.

`ParaAirIcon.svg` contains three polygons, including the badge. `ParaAirIcon.png` is the 1024-pixel application asset; `ParaAirDriveIcon.png` is the 256-pixel default drive asset; `ParaAirIcon.icns` contains the standard macOS icon sizes. The built app packages these resources under `Contents/Resources`, and its `CFBundleIconFile` is `ParaAirIcon`. Xcode and the CLI assembly script both include the assets.

`App/BrandMenuIcon.swift` draws the same flight geometry as a 20 × 18 point monochrome template without the badge. The geometry fits its own bounds and fills its two adjoining polygons in one path to avoid an antialiasing seam. macOS controls its light/dark color. Custom drive names and imported images remain available through **Drive appearance…** and take precedence over the default artwork. Finder presentation of the mounted volume remains a separate verification item.

Previews: `.runtime/paraair-glide-icon-preview.png` and `.runtime/paraair-menu-mark-preview-glide.png`. The master, drive PNG, and all PNG entries in the ICNS were checked for the exact three sRGB values and alpha 0/255. The SVG was checked for polygon-only geometry. Host compilation and strict deep signature verification passed. All installed artwork matches the source assets, and the restarted app's new header was visually verified on October 8. The existing `/Volumes/ParaAir` mount stayed active. The earlier appearance checks cover default artwork, IconRef support, custom import/persistence/reset, and invalid images; no storage logic changed in this revision. Actual menu-bar and Finder volume icon presentation remain unverified.

## Previous artwork provenance

The previous polygon A and its source are preserved in `.runtime/brand-history/20261008-polygon-a/`. Three abstract directions were drawn and compared at full and small sizes in `.runtime/icon-directions-20261008/`; Glide was chosen for its compact flight silhouette.

Six further abstract alternatives—Lift, Orbit, Layers, Shard, Pulse and Signal—are preserved as individual SVG/PNG files with a full/small-size comparison board in `.runtime/icon-directions-20261008/round-2/`. Their PNGs were checked for the exact three-color palette, and their SVGs contain only polygons. These are review candidates; the installed icon remains Glide.

The previous flowing ribbon design was generated with the built-in image_gen tool on October 8. Its assets and original branding notes are preserved in `.runtime/brand-history/20261008-ribbon/`; the original generated image remains in Codex's generated-images directory. Exact original prompt:

> Use case: logo-design. Asset type: production macOS application icon for ParaAir, a streaming cloud drive for creators. Design a polished, distinctive icon: one flowing capital A formed by two broad, smooth folded ribbons, with an open triangular counter and a clean small gap that suggests moving air and data. The silhouette must read at 16 pixels. Center this compact white and icy cyan mark on a deep midnight blue rounded square with soft dimensional bevels and restrained studio highlights. The mark should feel airy and precise, not busy, not a literal cloud or hard disk. Front view, square 1024x1024 composition, macOS app icon with transparent outer corners, tile centered with a narrow transparent margin. No text, no wordmark, no letters other than the abstract A mark, no badges, no tiny details, no mockup, no watermark, no background scene. Output a single ready-to-use icon.

The previous tool result was a 1254 × 1254 PNG with alpha. Its preview and signed-app proof remain at `.runtime/paraair-menu-mark-preview.png` and `.runtime/paraair-brand-live.png`.
