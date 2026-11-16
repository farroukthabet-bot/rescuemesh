// Pixel <-> GPS conversion for /public/cun-map.jpg (Google Maps screenshot, north up).
// Fitted by least squares on 6 control points: 4 donor locations and 2 roundabouts.
// Worst residual is about 5 px (about 7 m), good enough for a schematic demo map.
export const MAP = {
  src: "/cun-map-dark.jpg",
  width: 1136,
  height: 943,
  AX: 62751.89783561566, BX: -639111.4473500763,
  CY: -77407.56945786755, DY: 2852580.5698341606,
};

export function geoToPixel(lat: number, lng: number) {
  return { x: MAP.AX * lng + MAP.BX, y: MAP.CY * lat + MAP.DY };
}

export function pixelToGeo(x: number, y: number) {
  return { lat: (y - MAP.DY) / MAP.CY, lng: (x - MAP.BX) / MAP.AX };
}