const path = require("path");

const repoRoot = __dirname;
// Nama PM2 diturunkan dari nama folder, jadi 2 salinan (kantor, kantor2) tidak bentrok.
const inst = path.basename(repoRoot);

module.exports = {
  apps: [
    {
      name: `${inst}-agent`,
      script: path.join(repoRoot, "index.js"),
      cwd: repoRoot,
      interpreter: "node",
      instances: 1,
      exec_mode: "fork",
      autorestart: true,
      restart_delay: 5000,
      kill_timeout: 10000,
      max_restarts: 10,
      min_uptime: "10s",
      merge_logs: true,
      time: true,
      // Always start via this file (npm run pm2:start) so cwd + script path stay pinned to the repo.
      env: {
        NODE_ENV: "production",
      },
    },
    {
      // Tunnel gratis (Cloudflare Quick Tunnel). Tiap start dapat URL baru: ditulis ke .env,
      // tombol Telegram diperbarui, lalu agent "<folder>-agent" di-restart otomatis.
      // Jalankan lewat: pm2 start ecosystem.config.cjs --only <folder>-tunnel
      name: `${inst}-tunnel`,
      script: path.join(repoRoot, "scripts", "tunnel.js"),
      cwd: repoRoot,
      interpreter: "node",
      instances: 1,
      exec_mode: "fork",
      autorestart: true,
      restart_delay: 10000,
      kill_timeout: 8000,
      max_restarts: 1000,
      min_uptime: "20s",
      merge_logs: true,
      time: true,
      env: {
        NODE_ENV: "production",
      },
    },
  ],
};