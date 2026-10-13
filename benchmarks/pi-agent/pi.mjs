import fs from "node:fs";
import { performance } from "node:perf_hooks";
import { runAgentLoop } from "@earendil-works/pi-agent-core";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
const fixtures = JSON.parse(fs.readFileSync(new URL("./fixtures.json", import.meta.url)));
const model = {id:"mock", name:"mock", api:"openai-responses", provider:"openai",
  baseUrl:"https://example.invalid", reasoning:false, input:["text"],
  cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:128000,maxTokens:4096};
async function run(f) {
  if (!f.agents) return runOne(f);
  const outcomes=await Promise.all(Array.from({length:f.agents},()=>runOne(f)));
  return {requests:outcomes.reduce((n,o)=>n+o.requests,0),
    executions:outcomes.reduce((n,o)=>n+o.executions,0),results:outcomes.flatMap(o=>o.results)};
}
async function runOne(f) {
  let requests=0, executions=0;
  const tool={name:"work", label:"work", description:"Echo an integer",
    parameters:{type:"object",properties:{value:{type:"integer"}},required:["value"],additionalProperties:false},
    execute:async (_id,args)=>{
      executions++;
      if(f.delay_ms) await new Promise(r=>setTimeout(r,f.delay_ms));
      if(["failure","failed_stop"].includes(f.mode)) throw new Error("failed");
      return {content:[{type:"text",text:String(args.value)}],details:null};
    }};
  const config={model,convertToLlm:messages=>messages,
    toolExecution:f.parallel?"parallel":"sequential",
    beforeToolCall:f.mode==="blocked"?()=>({block:true,reason:"denied"}):undefined,
    afterToolCall:f.mode==="redacted"?()=>({content:[{type:"text",text:"redacted"}]}):
      ["stop","mixed_stop","failed_stop"].includes(f.mode)?({toolCall,isError})=>({terminate:toolCall.name==="work"&&!isError}):undefined};
  const streamFn=()=>{
    requests++;
    if(requests>f.rounds+1) throw new Error("unexpected request");
    const calls=requests<=f.rounds;
    const message={role:"assistant",api:model.api,provider:model.provider,model:model.id,
      timestamp:0,stopReason:calls?"toolUse":"stop",
      usage:{input:10,output:5,cacheRead:0,cacheWrite:0,totalTokens:15,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},
      content:calls?Array.from({length:f.batch},(_,i)=>({type:"toolCall",id:`c${requests}-${i+1}`,name:f.mode==="mixed_stop"&&i===1?"other":"work",arguments:{value:f.mode==="invalid"?"bad":f.mode==="coercion"?"1":i+1}})):
        [{type:"text",text:"done"}]};
    const stream=createAssistantMessageEventStream();
    queueMicrotask(()=>stream.push({type:"done",reason:message.stopReason,message}));
    return stream;
  };
  const messages=await runAgentLoop([{role:"user",content:"go",timestamp:0}],{messages:[],tools:f.mode==="mixed_stop"?[tool,{...tool,name:"other"}]:[tool]},
    config,()=>{},undefined,streamFn);
  return {requests,executions,results:messages.filter(m=>m.role==="toolResult").map(m=>({
    id:m.toolCallId,error:m.isError===true,content:m.isError?"<error>":m.content.map(c=>c.text??"").join("")}))};
}
const n=Number(process.env.BENCH_SAMPLES??100), rows=[];
for(const f of fixtures){
  const outcome=await run(f);
  for(let i=0;i<20;i++)await run(f);
  const samples_ms=[];
  for(let i=0;i<n;i++){
    const start=performance.now(), actual=await run(f);
    samples_ms.push(performance.now()-start);
    if(JSON.stringify(actual)!==JSON.stringify(outcome))throw new Error("nondeterministic result");
  }
  rows.push({name:f.name,outcome,samples_ms});
}
console.log(JSON.stringify({runtime:process.version,rows}));
