import {Router} from "express"
import {config} from "dotenv"
import {readFileSync} from "fs"

config({ quiet: true })

export const scripts = {
    startSSH: () => applyEnvVariables(readFileSync("./scripts/startSSH.ps1", "utf-8")),
}

function applyEnvVariables(scriptContent: string) {
    const envVars = {
        ENV_BASE_URL: process.env.BASE_URL!,
        ENV_TARGET: process.env.TARGET!,
        ENV_TARGET_PORT: process.env.TARGET_PORT || "22",
    }

    Object.keys(envVars).forEach((envKey) => {
        const envValue = envVars[envKey as keyof typeof envVars]
        const regex = new RegExp(`<<${envKey}>>`, "g")
        scriptContent = scriptContent.replace(regex, envValue)
    })

    return scriptContent
}

const scriptsRouter = Router()

scriptsRouter.get("/ssh", (req, res) => {
    res.header("Content-Type", "text/plain")
    res.send(scripts.startSSH())
})

export default scriptsRouter