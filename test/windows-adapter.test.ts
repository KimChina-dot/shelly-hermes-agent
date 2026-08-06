import assert from "node:assert/strict";import test from "node:test";import {createWindowsHostPaths} from "../src/adapters/windows/index.js";
test("derives deterministic Windows paths",()=>{const p=createWindowsHostPaths({LOCALAPPDATA:"C:\\Users\\u\\AppData\\Local"},"D:\\code\\agent");assert.equal(p.workspace,"D:\\code\\agent");assert.equal(p.state,"C:\\Users\\u\\AppData\\Local\\state")});
test("falls back inside workspace when appdata missing",()=>assert.match(createWindowsHostPaths({},"C:\\agent").state,/C:\\agent\\.shelly-hermes\\state/i));
