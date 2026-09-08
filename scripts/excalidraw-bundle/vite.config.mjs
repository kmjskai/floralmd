import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    assetsDir: "",
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: "excalidraw.js",
        chunkFileNames: "excalidraw-[hash].js",
        assetFileNames: "[name]-[hash][extname]"
      }
    }
  }
});
