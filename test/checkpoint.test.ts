import assert from "node:assert/strict";import test from "node:test";import { CheckpointStore,CheckpointSchemaError } from "../src/checkpoint/index.js";
class Store{m=new Map<string,string>();writes=0;async read(k:string){return this.m.get(k)}async writeAtomic(k:string,v:string){this.writes++;this.m.set(k,v)}async append(){}async exists(k:string){return this.m.has(k)}}
test("checkpoint saves atomically and loads",async()=>{const s=new Store(),c=new CheckpointStore<{ok:boolean}>(s,1);await c.save("x",{ok:true});assert.equal(s.writes,1);assert.deepEqual(await c.load("x"),{ok:true})});
test("checkpoint rejects wrong schema",async()=>{const s=new Store();s.m.set("x",'{"schemaVersion":2,"value":{}}');await assert.rejects(new CheckpointStore(s,1).load("x"),CheckpointSchemaError)});
