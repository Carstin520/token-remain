import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

export default defineConfig({
  plugins: [react()],
  base: "./",
  publicDir: false,
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        index: fileURLToPath(new URL("index.html", import.meta.url)),
        popover: fileURLToPath(new URL("popover.html", import.meta.url)),
        floating: fileURLToPath(new URL("floating.html", import.meta.url)),
      },
    },
  },
});
