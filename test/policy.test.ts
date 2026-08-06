import assert from "node:assert/strict"; import test from "node:test"; import { PolicyEngine } from "../src/policy/index.js";
const request=(risk:"read"|"dangerous", caps:any[])=>({id:"1",tool:"x",input:{},requiredCapabilities:caps,risk});
test("policy allows low risk with capability",()=>assert.equal(new PolicyEngine({capabilities:["fs.read"]}).evaluate(request("read",["fs.read"])).action,"allow"));
test("policy denies missing capability",()=>assert.equal(new PolicyEngine().evaluate(request("read",["fs.read"])).action,"deny"));
test("policy confirms dangerous action",()=>assert.equal(new PolicyEngine({capabilities:["delete"]}).evaluate(request("dangerous",["delete"])).action,"confirm"));
