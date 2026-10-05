import { startServer } from './server.mjs';
startServer({ demo: true }).catch((error) => { console.error(error.message); process.exitCode = 1; });
