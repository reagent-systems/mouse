import './style.css'
import { App } from './app.ts'
import { maybeInstallMockGitHub } from './platform/mockGitHub.ts'

// Install canned GitHub transport before the app boots, when ?mockgh=1.
maybeInstallMockGitHub()

new App(document.querySelector<HTMLDivElement>('#app')!)
