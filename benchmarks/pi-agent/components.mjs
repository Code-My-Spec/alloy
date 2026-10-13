import {performance} from 'node:perf_hooks';
import {validateToolArguments} from '@earendil-works/pi-ai';
import {runToolCall} from '@earendil-works/pi-agent-core';
const schema=()=>({type:'object',properties:{value:{type:'integer'}},required:['value'],additionalProperties:false});
const tool={name:'work',description:'Echo',parameters:schema(),execute:async()=>({content:[{type:'text',text:'1'}],details:null})};
const call={type:'toolCall',name:'work',id:'c1',arguments:{value:1}};
const opts={tools:[tool],context:{messages:[],tools:[tool]},assistantMessage:{role:'assistant',content:[call]}};
const rows=[];
for(const [name,fn] of [
 ['schema_cold_and_validate',()=>validateToolArguments({...tool,parameters:schema()},call)],
 ['validate_cached',()=>validateToolArguments(tool,call)],
 ['promise',async()=>await Promise.resolve('1')],
 ['run_tool_call_cached',()=>runToolCall(call,opts)]
]){
 for(let i=0;i<100;i++)await fn();
 const samples_us=[];
 for(let i=0;i<1000;i++){const start=performance.now();await fn();samples_us.push((performance.now()-start)*1000);}
 samples_us.sort((a,b)=>a-b);rows.push({name,median_us:samples_us[500],p95_us:samples_us[950],samples_us});
}
console.log(JSON.stringify({engine:'pi',rows}));
