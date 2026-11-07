// Downloads CC0 models and textures into web/public/assets (kept out of Git).
// Sources: Poly Haven (CC0, https://polyhaven.com/license) and the Khronos
// glTF-Sample-Assets WaterBottle (CC0-1.0).
import { mkdir, writeFile, access } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "public", "assets");
const MODELS = ["Sofa_01", "dining_chair_02", "coffee_table_round_01", "wooden_table_02",
  "tea_set_01", "potted_plant_01", "WoodenTable_02"];
const TEXTURES = ["wood_floor", "beige_wall_001"];
const EXTRA = {
  "WaterBottle/WaterBottle.glb":
    "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/WaterBottle/glTF-Binary/WaterBottle.glb",
};

async function save(rel, url) {
  const path = join(OUT, rel);
  try { await access(path); return; } catch {}
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: ${res.status}`);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, Buffer.from(await res.arrayBuffer()));
  console.log("saved", rel);
}

const files = async (id) => (await fetch(`https://api.polyhaven.com/files/${id}`)).json();

for (const id of MODELS) {
  const g = (await files(id)).gltf["1k"].gltf;
  await save(`${id}/${id}.gltf`, g.url);
  for (const [rel, f] of Object.entries(g.include)) await save(`${id}/${rel}`, f.url);
}
for (const id of TEXTURES) await save(`textures/${id}.jpg`, (await files(id)).Diffuse["1k"].jpg.url);
for (const [rel, url] of Object.entries(EXTRA)) await save(rel, url);
console.log("assets ready in", OUT);
