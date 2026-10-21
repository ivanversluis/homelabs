'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawnSync}=require('node:child_process');
const code=path.resolve(__dirname,'../k8s-query.js');
const mock=path.resolve(__dirname,'mock-k8s.js');
function run(args,extra={}){let r=spawnSync(process.execPath,[code,...args],{encoding:'utf8',timeout:5000,env:{...process.env,KUBERNETES_SERVICE_HOST:'kubernetes.default.svc',KUBERNETES_SERVICE_PORT:'443',NODE_OPTIONS:'--require='+mock,...extra}});let v;try{v=JSON.parse(r.stdout||r.stderr)}catch{v=r.stderr};return {r,v}}
const cases=[
[['summary'],v=>assert.equal(v.counts.unhealthyDeployments,1)],
[['pod','vault-raft-restore-test','vault-restore'],v=>{assert.equal(v.initContainers.length,1);assert.equal(v.pod.ready,'0/1')}],
[['logs','vault-raft-restore-test','vault-restore','--container','vault'],v=>assert.match(v.logs,/awaiting operator/)],
[['nodes'],v=>assert.equal(v[0].ready,true)],
[['deployments'],v=>assert.equal(v[0].rolloutStalled,true)],
[['statefulsets'],v=>assert.equal(v.length,0)],
[['daemonsets'],v=>assert.equal(v.length,0)],
[['jobs'],v=>assert.equal(v.length,0)],
[['cronjobs'],v=>assert.equal(v.length,0)],
[['pvcs'],v=>assert.equal(v[0].phase,'Bound')],
[['metrics-nodes'],v=>assert.equal(v[0].usage.cpu,'100m')],
[['events','vault-raft-restore-test','vault-restore'],v=>assert.equal(v[0].count,15767)],
];
for(let [a,check] of cases){let {r,v}=run(a);assert.equal(r.status,0,r.stderr);check(v)}
for(let a of [['unknown'],['logs','ns','pod','--tail','0'],['logs','ns','pod','--container','bad/slash']]){let {r}=run(a);assert.notEqual(r.status,0)}
let forbidden=run(['logs','vault-raft-restore-test','vault-restore'],{MOCK_FORBIDDEN:'/log'});assert.notEqual(forbidden.r.status,0);assert.match(forbidden.r.stderr,/HTTP 403/);
console.log('Passed 16/16 mocked Kubernetes read-only diagnostic checks');
