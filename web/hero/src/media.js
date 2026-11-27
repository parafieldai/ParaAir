// Everything that floats on the hero's canvas: photos, video loops and documents, each the file it would be on a
// ParaAir drive (its name and size show in the Mac's Finder). Photos and clips are free-licensed (Unsplash, Mixkit); the sources
// are listed in site/media/CREDITS.md. Documents are drawn by the page.

const P = (name, src, file, size, aspect) => ({ kind: "photo", name, src: `media/${src}.webp`, file, size, aspect });
const O = (name, src, file, size, aspect) => ({ kind: "photo", name, src: `photos/${src}.jpg`, file, size, aspect });
const V = (name, src, file, size, aspect) => ({ kind: "video", name, src: `media/${src}.mp4`, poster: `media/${src}.webp`, file, size, aspect });
const D = (name, doc, file, size, aspect, palette) => ({ kind: "doc", name, doc, file, size, aspect, palette });

export const MEDIA = [
  V("dancer", "dancer", "dance-take4.mov", "27 GB", 16 / 9),
  P("surf", "surf", "lineup_0731.NEF", "38.7 MB", 427 / 640),
  P("dad", "dad-shoulders", "beach-day_0412.HEIC", "3.9 MB", 900 / 772),
  D("guide", "pdf", "brand-guidelines.pdf", "96 MB", 0.77, ["#FFFFFF", "#141518", "#E9E6DF", "#E8B48E", "#141518", "#FFFFFF"]),
  P("red", "red-dress", "campaign_red_03.jpg", "14 MB", 640 / 434),
  O("interview", "interview-a", "interview-a-cam.mov", "52.1 GB", 4 / 3),
  P("arch", "blue-arch", "tower-sky.jpg", "9.8 MB", 640 / 427),
  V("flowers", "flowers", "bougainvillea.mov", "3.2 GB", 9 / 16),
  P("dinner", "friends-dinner", "dinner-with-friends.jpg", "5.2 MB", 900 / 600),
  D("sheet", "sheet", "shoot-budget.xlsx", "846 KB", 1.32, ["#FFFFFF", "#E7E5E0", "#141518", "#FFFFFF", "#CFE3D6"]),
  P("pink", "portrait-pink", "portrait_pink.cr3", "61 MB", 427 / 640),
  O("lake", "lake", "drone-river.mov", "18.4 GB", 4 / 3),
  P("camera", "film-camera", "yashica-roll.tif", "120 MB", 427 / 640),
  V("campfire", "campfire", "campfire-night.mov", "31.6 GB", 16 / 9),
  P("concert", "concert", "live-set_blue.jpg", "22 MB", 427 / 640),
  P("grandma", "grandma-hug", "grandma-visit_22.HEIC", "4.4 MB", 900 / 602),
  P("ceramics", "ceramics", "ceramics_still.psd", "340 MB", 427 / 640),
  P("bike", "bicycle", "fixie-white.jpg", "7.4 MB", 640 / 427),
  O("studio", "studio", "stills-day-2.jpg", "14 MB", 4 / 3),
  P("road", "desert-road", "route-66.dng", "64 MB", 640 / 427),
  P("violet", "portrait-violet", "studio-violet.jpg", "18 MB", 640 / 427),
  D("notes", "md", "call-notes.md", "7 KB", 0.8, ["#FFFFFF", "#141518", "#D9DBDF", "#FFFFFF"]),
  P("skate", "skateboard", "deck-yellow.png", "4.1 MB", 512 / 640),
  P("tulips", "tulips", "tulips_v2.jpg", "9.1 MB", 427 / 640),
  P("alps", "banff-lake", "alps-timelapse.mov", "22.6 GB", 900 / 600),
  P("night", "city-night", "night-walk.cr3", "58 MB", 427 / 640),
  V("skater", "skater", "skate-park.mov", "5.8 GB", 16 / 9),
  P("yellow", "yellow-still", "set-yellow.psd", "210 MB", 640 / 427),
  D("blend", "blend", "render_v4.blend", "486 MB", 1.36, ["#26272B", "#F29A3A", "#9AA0AA", "#3A3B40"]),
  O("podcast", "podcast", "review-cut.mp4", "6.4 GB", 4 / 3),
  P("glasses", "glasses", "frames-white.tif", "88 MB", 640 / 428),
  O("interview-b", "interview-b", "interview-b-cam.mov", "41.7 GB", 4 / 3),
  // In the Finder only, never on the canvas.
  D("wav", "wav", "score-final.wav", "1.2 GB", 2.1, ["#1D1E21", "#E9EAEC", "#2A2B2F", "#B9BCC2"]),
];

// The files the Mac's Finder fills with as the streams arrive, in order.
export const FINDER_FILES = ["interview", "dancer", "lake", "surf", "guide", "skater", "red", "sheet", "flowers", "wav", "camera", "campfire"];
