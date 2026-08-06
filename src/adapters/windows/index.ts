import { win32 } from "node:path";import { NodeProcessAdapter,NodeTextStore } from "../node/index.js";
export interface WindowsHostPaths{workspace:string;appData:string;state:string}
export function createWindowsHostPaths(env:Readonly<Record<string,string|undefined>>,cwd:string):WindowsHostPaths{const workspace=win32.resolve(cwd);const appData=win32.resolve(env.LOCALAPPDATA??win32.join(workspace,".shelly-hermes"));return {workspace,appData,state:win32.join(appData,"state")}}
export function createWindowsHost(paths:WindowsHostPaths){return {store:new NodeTextStore(paths.state),process:new NodeProcessAdapter(paths.workspace),paths}}
