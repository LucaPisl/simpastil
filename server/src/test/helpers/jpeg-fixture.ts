// A structurally valid JPEG for tests: SOI, JFIF, optional APP1, SOF0, SOS,
// filler "scan" bytes and EOI. It is not decodable as a picture; the server
// reads only the segment structure and the size.
export interface JpegFixtureOptions {
  width: number;
  height: number;
  /** Payload of an APP1 segment to include (Exif or XMP). */
  app1?: Buffer;
  /** Total length in bytes; the scan is padded to reach it. */
  size?: number;
  /** A byte to pad the scan with, to make two photos differ. */
  filler?: number;
}

function segment(marker: number, body: Buffer): Buffer {
  const header = Buffer.alloc(4);
  header[0] = 0xff;
  header[1] = marker;
  header.writeUInt16BE(body.length + 2, 2);
  return Buffer.concat([header, body]);
}

export function makeJpeg(options: JpegFixtureOptions): Buffer {
  const sof = Buffer.alloc(15);
  sof[0] = 8; // precision
  sof.writeUInt16BE(options.height, 1);
  sof.writeUInt16BE(options.width, 3);
  sof[5] = 3; // components
  sof.set([1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1], 6);
  const sos = Buffer.from([3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0]);
  const parts = [
    Buffer.from([0xff, 0xd8]),
    segment(0xe0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'latin1')),
    ...(options.app1 ? [segment(0xe1, options.app1)] : []),
    segment(0xc0, sof),
    segment(0xda, sos),
  ];
  const head = Buffer.concat(parts);
  const tail = Buffer.from([0xff, 0xd9]);
  const scanLength = Math.max(16, (options.size ?? head.length + 64 + tail.length) - head.length - tail.length);
  // Entropy data cannot contain a bare 0xFF; a constant non-FF byte is safe.
  const scan = Buffer.alloc(scanLength, options.filler ?? 0x55);
  return Buffer.concat([head, scan, tail]);
}
