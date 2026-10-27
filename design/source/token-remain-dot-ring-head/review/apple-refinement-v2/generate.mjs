// Stage A refinement only. Exact O4-C geometry, editable vector material study.
// SHARP_MODULE may point to the existing bundled sharp package; no installation.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const sharp = require(process.env.SHARP_MODULE || 'sharp');
const out = path.dirname(fileURLToPath(import.meta.url));
const prior = path.dirname(out);
const geometry = JSON.parse(await fs.readFile(path.join(prior, 'geometry.json'), 'utf8'));
const variants = ['full', 'medium', 'small'];
const sizes = [1024, 256, 128, 64, 48, 32, 24, 16];

function primitive(p, fill = p.fill, extra = '') {
  return p.kind === 'circle'
    ? `<circle cx="${p.cx}" cy="${p.cy}" r="${p.r}" fill="${fill}" ${extra}/>`
    : `<rect x="${p.x}" y="${p.y}" width="${p.w}" height="${p.h}" rx="${p.r}" fill="${fill}" ${extra}/>`;
}
function materialSVG(variant, surface = 'tile', appearance = 'default', lit) {
  const mono = appearance === 'tinted';
  const shapes = structuredClone(geometry.variants[variant]);
  if (lit !== undefined) for (const p of shapes.filter(p => p.group === 'Ring')) {
    p.role = p.index < lit ? 'lit' : 'dim';
    p.fill = geometry.palette[p.role];
  }
  const defs = `<defs>
    <linearGradient id="shell" x1="0" y1="0" x2="0.18" y2="1"><stop stop-color="#B4A3FA"/><stop offset=".45" stop-color="#8F7BF2"/><stop offset="1" stop-color="#7B68DB"/></linearGradient>
    <linearGradient id="depth" x2="0" y2="1"><stop stop-color="#6B5CC5"/><stop offset="1" stop-color="#4B4099"/></linearGradient>
    <linearGradient id="antenna" x2="0" y2="1"><stop stop-color="#D4CBFC"/><stop offset="1" stop-color="#B7A9F7"/></linearGradient>
    <linearGradient id="edge" x1="0" y1="0" x2=".35" y2="1"><stop stop-color="#F0EAFF" stop-opacity=".65"/><stop offset=".4" stop-color="#E0D5FF" stop-opacity=".07"/><stop offset="1" stop-color="#38266B" stop-opacity=".28"/></linearGradient>
    <radialGradient id="softLight" cx=".15" cy=".04" r=".85"><stop stop-color="#ECE4FF" stop-opacity=".25"/><stop offset=".65" stop-color="#B9A6FF" stop-opacity="0"/></radialGradient>
    <filter id="edgeSoftness" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="4"/></filter>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="13" flood-color="#000000" flood-opacity=".28"/></filter>
    <clipPath id="headClip">${shapes.filter(p=>p.role==='shell').map(p=>primitive(p)).join('')}</clipPath>
    <clipPath id="crop">${surface === 'watchos' ? '<circle cx="512" cy="512" r="512"/>' : surface === 'macos' ? '<rect x="100" y="100" width="824" height="824" rx="185.4"/>' : '<rect width="1024" height="1024" rx="224"/>'}</clipPath>
  </defs>`;
  const base = mono ? '#000000' : '#081431';
  let content = `<rect width="1024" height="1024" fill="${base}"/>`;
  content += shapes.filter(p=>p.group==='Ring').map(p=>primitive(p,mono?geometry.mono[p.role]:p.fill)).join('');
  const head = shapes.filter(p=>p.group==='Head');
  content += `<g ${!mono && variant!=='small' ? 'filter="url(#shadow)"' : ''}>`;
  content += head.map(p=>primitive(p,mono ? geometry.mono[p.role] : `url(#${p.role})`)).join('');
  content += '</g>';
  if (!mono) {
    const p=head.find(p=>p.role==='shell');
    content += `<g clip-path="url(#headClip)">${primitive(p,'url(#softLight)')}<rect x="${p.x+7}" y="${p.y+7}" width="${p.w-14}" height="${p.h-14}" rx="${p.r-7}" fill="none" stroke="url(#edge)" stroke-width="18" filter="url(#edgeSoftness)"/></g>`;
  }
  content += shapes.filter(p=>p.group==='Face').map(p=>primitive(p,mono?geometry.mono[p.role]:p.fill)).join('');
  if (!mono) {
    const p=shapes.find(p=>p.role==='screen');
    content += `<rect x="${p.x+2}" y="${p.y+2}" width="${p.w-4}" height="${p.h-4}" rx="${p.r-2}" fill="none" stroke="#4A3E6F" stroke-opacity=".45" stroke-width="4"/>`;
  }
  if (surface==='macos') content=`<g clip-path="url(#crop)"><g transform="translate(100 100) scale(0.8046875)">${content}</g></g>`;
  else if (surface!=='tile') content=`<g clip-path="url(#crop)">${content}</g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">${defs}${content}</svg>`;
}

async function write(file, data) {
  await fs.mkdir(path.dirname(file), { recursive:true });
  await fs.writeFile(file,data);
}
async function png(svg, size) {
  return sharp(Buffer.from(svg), {density:144}).resize(size,size).withIccProfile('srgb').png().toBuffer();
}
for(const variant of variants) {
  for(const appearance of ['default','dark','tinted']) {
    const svg=materialSVG(variant,'tile',appearance);
    await write(path.join(out,'masters',appearance,`${variant}-1024.svg`),svg);
    await write(path.join(out,'masters',appearance,`${variant}-1024.png`),await png(svg,1024));
  }
  for(const size of sizes) {
    const svg=materialSVG(variant);
    await write(path.join(out,'sizes',`${variant}-${size}.png`),await png(svg,size));
  }
  for(const surface of ['ios','macos','watchos']) {
    const svg=materialSVG(variant,surface);
    await write(path.join(out,'platforms',`${variant}-${surface}.svg`),svg);
    await write(path.join(out,'platforms',`${variant}-${surface}.png`),await png(svg,1024));
  }
  // Native package keeps the unbaked base layers. The system owns the lighting.
  // Do not combine a baked material rendering with native glass effects.
  const source=path.join(prior,'composer',`TokenRemain-${variant}.icon`);
  const target=path.join(out,'composer',`TokenRemain-${variant}.icon`);
  await fs.cp(source,target,{recursive:true});
  const filename=path.join(target,'icon.json');
  const icon=JSON.parse(await fs.readFile(filename,'utf8'));
  // Icon Composer 1.6 omits this key for sRGB. The value "srgb" is rejected.
  delete icon['color-space-for-untagged-svg-colors'];
  // Native JSON arrays are front-to-back; the brief lists back-to-front.
  icon.groups.reverse();
  for(const group of icon.groups) group.layers.reverse();
  const head=icon.groups.find(g=>g.name==='Head');
  head.lighting='combined';
  // combined avoids a separate glass ridge where the antenna meets the shell.
  // macOS-only platform selection is deliberately retained from the brief.
  await write(filename,JSON.stringify(icon,null,2)+'\n');
}
for(const count of [20,15,10,5,1,0]) {
  const svg=materialSVG('full','macos','default',count);
  await write(path.join(out,'runtime',`full-${String(count).padStart(2,'0')}.svg`),svg);
  await write(path.join(out,'runtime',`full-${String(count).padStart(2,'0')}.png`),await png(svg,1024));
}
// Review-only enclosure document. Shipping macOS documents stay macOS-only;
// native watchOS exports need an enabled circular enclosure in this separate copy.
{
  const target=path.join(out,'composer','TokenRemain-platform-preview.icon');
  await fs.cp(path.join(out,'composer','TokenRemain-full.icon'),target,{recursive:true});
  const file=path.join(target,'icon.json');
  const icon=JSON.parse(await fs.readFile(file,'utf8'));
  icon['supported-platforms']={squares:'shared',circles:['watchOS']};
  await write(file,JSON.stringify(icon,null,2)+'\n');
}
console.log('Material SVG/PNG masters, three size variants, crops, states and native unbaked layer packages generated.');
