import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    // The acer-ec-web systemd service already runs on this machine; proxy the
    // API so `npm run dev` exercises the real backend.
    proxy: {
      "/api": "http://127.0.0.1:8077",
    },
  },
});
