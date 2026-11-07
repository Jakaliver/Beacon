import { resolve } from "node:path";
import { defineConfig } from "vite";

export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        index: resolve(__dirname, "index.html"),
        viewer: resolve(__dirname, "reconstruction-viewer/index.html"),
      },
    },
  },
});
