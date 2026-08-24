import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync, inflateSync } from "node:zlib";

const ICON_SIZES = [16, 24, 32, 48, 64, 128, 256];
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
const sourcePath = fileURLToPath(new URL("../../site/assets/brand/appicon-mac.png", import.meta.url));
const outputPath = fileURLToPath(new URL("../build/icon.ico", import.meta.url));

function paethPredictor(left, up, upperLeft) {
  const prediction = left + up - upperLeft;
  const leftDistance = Math.abs(prediction - left);
  const upDistance = Math.abs(prediction - up);
  const upperLeftDistance = Math.abs(prediction - upperLeft);
  if (leftDistance <= upDistance && leftDistance <= upperLeftDistance) return left;
  return upDistance <= upperLeftDistance ? up : upperLeft;
}

function decodePNG(source) {
  if (!source.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) throw new Error("Source is not a PNG");
  let offset = PNG_SIGNATURE.length;
  let header;
  const imageData = [];
  while (offset + 12 <= source.length) {
    const length = source.readUInt32BE(offset);
    const type = source.toString("ascii", offset + 4, offset + 8);
    const data = source.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      header = {
        width: data.readUInt32BE(0),
        height: data.readUInt32BE(4),
        bitDepth: data[8],
        colorType: data[9],
        compression: data[10],
        filter: data[11],
        interlace: data[12],
      };
    } else if (type === "IDAT") {
      imageData.push(data);
    } else if (type === "IEND") {
      break;
    }
    offset += length + 12;
  }
  if (!header || imageData.length === 0) throw new Error("PNG is missing IHDR or IDAT data");
  if (header.bitDepth !== 8 || ![2, 6].includes(header.colorType)
    || header.compression !== 0 || header.filter !== 0 || header.interlace !== 0) {
    throw new Error("Only non-interlaced 8-bit RGB/RGBA PNG sources are supported");
  }

  const channels = header.colorType === 6 ? 4 : 3;
  const rowLength = header.width * channels;
  const filtered = inflateSync(Buffer.concat(imageData));
  if (filtered.length !== header.height * (rowLength + 1)) throw new Error("Unexpected PNG pixel data length");
  const pixels = Buffer.alloc(header.width * header.height * 4);
  let filteredOffset = 0;
  let priorRow = Buffer.alloc(rowLength);
  for (let y = 0; y < header.height; y += 1) {
    const filterType = filtered[filteredOffset];
    filteredOffset += 1;
    const row = Buffer.allocUnsafe(rowLength);
    for (let x = 0; x < rowLength; x += 1) {
      const encoded = filtered[filteredOffset + x];
      const left = x >= channels ? row[x - channels] : 0;
      const up = priorRow[x];
      const upperLeft = x >= channels ? priorRow[x - channels] : 0;
      let predictor;
      if (filterType === 0) predictor = 0;
      else if (filterType === 1) predictor = left;
      else if (filterType === 2) predictor = up;
      else if (filterType === 3) predictor = Math.floor((left + up) / 2);
      else if (filterType === 4) predictor = paethPredictor(left, up, upperLeft);
      else throw new Error(`Unsupported PNG filter ${filterType}`);
      row[x] = (encoded + predictor) & 0xFF;
    }
    filteredOffset += rowLength;
    for (let x = 0; x < header.width; x += 1) {
      const sourceOffset = x * channels;
      const targetOffset = (y * header.width + x) * 4;
      pixels[targetOffset] = row[sourceOffset];
      pixels[targetOffset + 1] = row[sourceOffset + 1];
      pixels[targetOffset + 2] = row[sourceOffset + 2];
      pixels[targetOffset + 3] = channels === 4 ? row[sourceOffset + 3] : 0xFF;
    }
    priorRow = row;
  }
  return { ...header, pixels };
}

function resizeRGBA(source, size) {
  const output = Buffer.alloc(size * size * 4);
  const scaleX = source.width / size;
  const scaleY = source.height / size;
  for (let y = 0; y < size; y += 1) {
    const sourceY = Math.max(0, Math.min(source.height - 1, (y + 0.5) * scaleY - 0.5));
    const y0 = Math.floor(sourceY);
    const y1 = Math.min(source.height - 1, y0 + 1);
    const yWeight = sourceY - y0;
    for (let x = 0; x < size; x += 1) {
      const sourceX = Math.max(0, Math.min(source.width - 1, (x + 0.5) * scaleX - 0.5));
      const x0 = Math.floor(sourceX);
      const x1 = Math.min(source.width - 1, x0 + 1);
      const xWeight = sourceX - x0;
      const targetOffset = (y * size + x) * 4;
      for (let channel = 0; channel < 4; channel += 1) {
        const topLeft = source.pixels[(y0 * source.width + x0) * 4 + channel];
        const topRight = source.pixels[(y0 * source.width + x1) * 4 + channel];
        const bottomLeft = source.pixels[(y1 * source.width + x0) * 4 + channel];
        const bottomRight = source.pixels[(y1 * source.width + x1) * 4 + channel];
        const top = topLeft + (topRight - topLeft) * xWeight;
        const bottom = bottomLeft + (bottomRight - bottomLeft) * xWeight;
        output[targetOffset + channel] = Math.round(top + (bottom - top) * yWeight);
      }
    }
  }
  return output;
}

const CRC_TABLE = Array.from({ length: 256 }, (_, value) => {
  let crc = value;
  for (let bit = 0; bit < 8; bit += 1) crc = (crc & 1) ? 0xEDB88320 ^ (crc >>> 1) : crc >>> 1;
  return crc >>> 0;
});

function crc32(buffer) {
  let crc = 0xFFFFFFFF;
  for (const byte of buffer) crc = CRC_TABLE[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

function pngChunk(type, data) {
  const typeBuffer = Buffer.from(type, "ascii");
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length, 0);
  typeBuffer.copy(chunk, 4);
  data.copy(chunk, 8);
  chunk.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])), 8 + data.length);
  return chunk;
}

function encodePNG(size, pixels) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 6;
  const scanlines = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y += 1) {
    pixels.copy(scanlines, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  }
  return Buffer.concat([
    PNG_SIGNATURE,
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(scanlines, { level: 9 })),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function encodeICO(images) {
  const directory = Buffer.alloc(6 + images.length * 16);
  directory.writeUInt16LE(0, 0);
  directory.writeUInt16LE(1, 2);
  directory.writeUInt16LE(images.length, 4);
  let imageOffset = directory.length;
  images.forEach(({ size, png }, index) => {
    const entryOffset = 6 + index * 16;
    directory[entryOffset] = size === 256 ? 0 : size;
    directory[entryOffset + 1] = size === 256 ? 0 : size;
    directory.writeUInt16LE(1, entryOffset + 4);
    directory.writeUInt16LE(32, entryOffset + 6);
    directory.writeUInt32LE(png.length, entryOffset + 8);
    directory.writeUInt32LE(imageOffset, entryOffset + 12);
    imageOffset += png.length;
  });
  return Buffer.concat([directory, ...images.map(({ png }) => png)]);
}

const source = decodePNG(await readFile(sourcePath));
const images = ICON_SIZES.map((size) => ({ size, png: encodePNG(size, resizeRGBA(source, size)) }));
await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, encodeICO(images));
console.log(`Generated ${outputPath} with PNG-compressed entries: ${ICON_SIZES.join(", ")}px`);
