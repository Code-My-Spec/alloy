import fs from 'node:fs';
import readline from 'node:readline';
import {performance} from 'node:perf_hooks';
import {runAgentLoop} from '@earendil-works/pi-agent-core';
import {stream} from '@earendil-works/pi-ai/api/google-generative-ai';
const specs=JSON.parse(fs.readFileSync(new URL('./tools.json',import.meta.url)));
const system=fs.readFileSync(new URL('./system.txt',import.meta.url),'utf8');
async function run(f){
 const calls=[];let requests=0,toolErrors=0;
 const model={id:f.model,name:f.model,api:'google-generative-ai',provider:'google',baseUrl:f.url+'/v1beta',reasoning:true,input:['text'],contextWindow:1048576,maxTokens:512,cost:{input:0.3,output:2.5,cacheRead:0.03,cacheWrite:0}};
 const tools=specs.map(s=>({name:s.name,label:s.name,description:s.description,parameters:f.contract==='enum'&&s.name==='lookup'?{...s.schema,properties:{key:{...s.schema.properties.key,enum:Object.keys(f.task.data).sort()}}}:s.schema,execute:async(id,args)=>{
  let result;
  if(s.name==='lookup')result=f.task.data[args.key]??{error:'unknown key'};
  if(s.name==='calculate')result={value:args.op==='add'?args.a+args.b:args.op==='subtract'?args.a-args.b:args.a*args.b};
  if(s.name==='submit_answer')result=args.answer;
  calls.push({name:s.name,args,result});
  if(result.error)throw Error(result.error);
  return {content:[{type:'text',text:JSON.stringify(result)}],details:null};
 }}));
 const start=performance.now();
 try{
  const messages=await runAgentLoop([{role:'user',content:f.task.prompt,timestamp:0}],
   {messages:[{role:'system',content:system}],tools},
   {model,convertToLlm:x=>x,toolExecution:'parallel',
    afterToolCall:f.policy==='stop'?({toolCall,isError})=>({terminate:toolCall.name==='submit_answer'&&!isError}):undefined},
   event=>{if(event.type==='tool_execution_end'&&event.isError)toolErrors++;},AbortSignal.timeout(120000),
   (m,context)=>{if(++requests>8)throw Error('request limit');return stream(m,context,{apiKey:'benchmark-proxy',temperature:0,maxTokens:512,thinking:{enabled:false}});});
  const last=messages.at(-1),failed=messages.some(m=>m.role==='assistant'&&['error','aborted'].includes(m.stopReason));
  return {status:failed?'error':'ok',tool_errors:toolErrors,text:last?.content?.filter(c=>c.type==='text').map(c=>c.text).join('')??'',calls,turns:requests,elapsed_ms:performance.now()-start,
    error:failed?messages.find(m=>m.errorMessage)?.errorMessage:undefined};
 }catch(e){return {status:'error',error:e.message,calls,turns:requests,elapsed_ms:performance.now()-start};}
}
console.log('READY');
for await(const line of readline.createInterface({input:process.stdin})){console.log(JSON.stringify(await run(JSON.parse(line))));}
