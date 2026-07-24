import {Router} from "express"
import {config} from "dotenv"
import {readFileSync} from "fs"

config({ quiet: true })

const scripts = {
    startSSH: readFileSync("./scripts/startSSH.ps1", "utf-8"),
}

Object.keys(scripts).forEach((key) => {
    const scriptKey = key as keyof typeof scripts
    const envVars = {
        ENV_BASE_URL: process.env.BASE_URL!,
        ENV_TARGET: process.env.TARGET!,
        ENV_TARGET_PORT: process.env.TARGET_PORT || "22",
    }

    let scriptContent = scripts[scriptKey]

    Object.keys(envVars).forEach((envKey) => {
        const envValue = envVars[envKey as keyof typeof envVars]
        const regex = new RegExp(`<<${envKey}>>`, "g")
        scriptContent = scriptContent.replace(regex, envValue)
    })

    scripts[scriptKey] = scriptContent
})

const scriptsRouter = Router()

scriptsRouter.get("/ssh", (req, res) => {
    res.header("Content-Type", "text/plain")
    res.send(scripts.startSSH)
})

export default scriptsRouter