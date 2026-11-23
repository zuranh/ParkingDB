import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite builds the React front end.
//  - "npm run dev"   : live-reload development server on http://localhost:3000.
//                      Calls to /api/... are forwarded (proxied) to the C# Web API
//                      on http://localhost:5000, so the browser only talks to one address.
//  - "npm run build" : writes the finished site into ../ParkingWeb/wwwroot,
//                      where the C# Web API serves it on http://localhost:5000.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: { "/api": "http://localhost:5000" },
  },
  build: {
    outDir: "../ParkingWeb/wwwroot",
    emptyOutDir: true,
  },
});
