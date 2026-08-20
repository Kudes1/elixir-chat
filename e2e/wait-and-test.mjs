import {spawn} from "node:child_process"

const url = process.env.BASE_URL || "http://web-e2e:4000"
const deadline = Date.now() + 120_000

while (Date.now() < deadline) {
  try {
    const response = await fetch(`${url}/login`)
    if (response.ok) break
  } catch (_) {}
  await new Promise(resolve => setTimeout(resolve, 1000))
}

if (Date.now() >= deadline) throw new Error(`Orbit did not become ready at ${url}`)

const child = spawn("npx", ["playwright", "test"], {stdio: "inherit", shell: false})
child.on("exit", code => process.exit(code ?? 1))
