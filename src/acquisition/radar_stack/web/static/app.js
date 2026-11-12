'use strict';
const $=id=>document.getElementById(id);let token='',snapshot=null,dirty=false,loaded=false,points=[],page='capture',lastHistory=0,acqDirty=false,deviceSignature='';
const esc=s=>String(s??'—').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const num=(v,d=2)=>Number.isFinite(Number(v))?Number(v).toFixed(d):'—';
const gib=v=>num(v/1024**3);const duration=s=>{s=Math.max(0,Math.floor(s||0));return [Math.floor(s/3600),Math.floor(s/60)%60,s%60].map(v=>String(v).padStart(2,'0')).join(':')};
const date=s=>s?new Date(s).toLocaleString('zh-CN',{hour12:false}):'—';
function notice(text){$('notice').textContent=text;$('notice').hidden=!text}
async function api(path,data){const response=await fetch(path,{method:data===undefined?'GET':'POST',headers:data===undefined?{}:{'Content-Type':'application/json','X-Radar-Token':token},body:data===undefined?undefined:JSON.stringify(data),signal:AbortSignal.timeout(20000)});const body=await response.json();if(!response.ok)throw Error(body.error||'请求失败');return body}
function pill(id,text,kind=''){$(id).textContent=text;$(id).className='pill '+kind}
function details(id,rows){$(id).innerHTML=rows.map(([k,v])=>`<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}
function switchPage(next){page=next;document.querySelectorAll('.page').forEach(el=>el.classList.toggle('active',el.id===next));document.querySelectorAll('.nav').forEach(el=>el.classList.toggle('active',el.dataset.page===next));$('page-title').textContent={capture:'采集控制',settings:'参数设置',history:'采集记录'}[next];if(next==='history')history()}
document.querySelectorAll('[data-page]').forEach(el=>el.addEventListener('click',()=>switchPage(el.dataset.page)));
function timing(profile){const t=profile.timing;if(!t)return;details('timing-details',[
 ['实际帧率',num(t.frame_rate_hz,3)+' Hz'],['帧内 chirp 间隔',num(t.chirp_period_us,2)+' μs'],
 ['跨帧 chirp 间隔',num(t.frame_boundary_interval_us,2)+' μs'],['实际帧间空闲',num(t.frame_blank_time_ms,4)+' ms'],
 ['跨帧 / 帧内间隔',num(t.boundary_to_regular_interval_ratio,2)+' 倍'],['预计原始速率',num(profile.rate_mib_s)+' MiB/s'],
 ['单个 bin',num(profile.bin_bytes/1024**2)+' MiB'],['每小时原始数据',num(profile.rate_mib_s*3600/1024)+' GiB'],
 ['DCA 预计负载',num((profile.budget?.dca_utilization||0)*100,1)+'%']]);}
function populate(profile){if(!profile.parameters||dirty)return;for(const [key,v]of Object.entries(profile.parameters)){const input=$('parameters').elements.namedItem(key);if(input)input.value=key==='tx'?v[0]:['fps','ramp_us','blank_ms'].includes(key)?Number(Number(v).toFixed(4)):v}loaded=true;timing(profile)}
function draw(){const canvas=$('chart'),ctx=canvas.getContext('2d'),w=canvas.width,h=canvas.height;ctx.clearRect(0,0,w,h);const max=Math.max(10,snapshot?.profile?.rate_mib_s||0,...points)*1.15;ctx.strokeStyle='#edf2f5';ctx.fillStyle='#97a7b2';ctx.font='11px sans-serif';for(let i=0;i<4;i++){const y=15+i*(h-35)/3;ctx.beginPath();ctx.moveTo(35,y);ctx.lineTo(w,y);ctx.stroke();ctx.fillText((max*(3-i)/3).toFixed(0),0,y+4)}if(!points.length)return;const coords=points.map((v,i)=>[35+(w-40)*(60-points.length+i)/59,h-20-(h-35)*v/max]);ctx.beginPath();ctx.moveTo(coords[0][0],h-20);coords.forEach(([x,y])=>ctx.lineTo(x,y));ctx.lineTo(coords.at(-1)[0],h-20);ctx.closePath();ctx.fillStyle='#e8f5f1';ctx.fill();ctx.beginPath();coords.forEach(([x,y],i)=>i?ctx.lineTo(x,y):ctx.moveTo(x,y));ctx.strokeStyle='#2b9a89';ctx.lineWidth=2;ctx.stroke()}
async function poll(){try{const s=await api('/api/status');snapshot=s;const active=s.capture.active,busy=s.operation.busy,p=s.profile,m=s.metrics; renderCamera(s);
 $('connection-text').textContent='已连接 NX';$('connection-dot').className='dot';$('clock').textContent=new Date(s.server_time).toLocaleTimeString('zh-CN',{hour12:false});
 const stopping=['manual_stop_requested','stopping'].includes(s.capture.runtime?.state);pill('capture-pill',active?(stopping?'正在停止':s.capture.runtime?.state==='degraded'?'部分通道异常':'采集中'):busy?'准备中':'待机',active?'ok':busy?'warn':'');
 $('duration').textContent=duration(m.elapsed_s);$('written').innerHTML=`${gib(m.written_bytes||0)} <em>GiB</em>`;$('bin-count').textContent=`雷达 ${m.complete_segments||0} 个 bin · 视频 ${m.camera_segments||0} 段`;
 $('rate').innerHTML=`${num(m.rate_mib_s||0,1)} <em>MiB/s</em>`;$('expected-rate').textContent=`预计 ${num(p.rate_mib_s,1)} MiB/s`;
 $('free-disk').innerHTML=`${gib(s.disk.free_bytes)} <em>GiB</em>`;$('remaining').textContent=s.disk.estimated_remaining_s==null?'开始采集后估算剩余时长':`预计还能采 ${num(s.disk.estimated_remaining_s/3600,1)} 小时`;
 $('session-label').textContent=active?s.capture.label:'等待下一次采集';$('profile-name').textContent=p.name||'配置异常';$('storage-path').textContent=s.storage_root;
 pill('hardware-pill',s.hardware.ready?'已就绪':'未就绪',s.hardware.ready?'ok':'warn');$('hardware-issues').textContent=s.hardware.issues.join('；');$('link').textContent=`${s.hardware.link_mbps} Mb/s · ${s.hardware.address}`;
 const faults=['duplicate_packets','out_of_order_packets','byte_gaps','queue_overflows','sequence_mismatches','short_packets','oversized_packets','source_ip_anomalies','source_port_anomalies','byte_stride_mismatches','trailing_unresolved_packets'].reduce((v,k)=>v+(m[k]||0),0);
 $('quality').textContent=active?(m.stale?'等待接收数据 / 状态暂未更新':faults?`发现 ${faults} 项异常计数`:'正常 · 未发现传输异常'):'等待采集';$('reserve').textContent=`${gib(s.disk.reserve_bytes)} GiB + 收尾余量`;
 $('start').disabled=active||busy||(s.acquisition.radar_enabled&&(!s.hardware.ready||!!p.error))||(!s.acquisition.radar_enabled&&!s.acquisition.camera_enabled)||(s.acquisition.camera_enabled&&!!s.camera.mode_error);$('stop').disabled=!active&&!busy;$('start').textContent=busy?'正在准备…':'开始采集';
 $('session-name').disabled=active||busy;$('session-note').disabled=active||busy;
 $('parameters').querySelectorAll('button').forEach(b=>b.disabled=active||busy);
 $('operation').hidden=!s.operation.message;$('operation').textContent=s.operation.message||'';
 if(p.error)notice(p.error);else if(loaded&&$('notice').dataset.network==='true'){notice('');delete $('notice').dataset.network}
 if(p.timing)details('summary',[['物理帧率',num(p.timing.frame_rate_hz,2)+' Hz'],['每帧 chirp / ADC 点数',`${p.timing.chirps_per_frame} / ${p.timing.adc_samples}`],['帧内 / 跨帧间隔',`${num(p.timing.chirp_period_us,2)} / ${num(p.timing.frame_boundary_interval_us,2)} μs`],['bin 大小',num(p.bin_bytes/1024**2)+' MiB']]);
 pill('validation-pill',p.validated?'配置已验证':'开始时自动短采验证',p.validated?'ok':'warn');populate(p);
 points.push(active?(m.rate_mib_s||0):0);if(points.length>60)points.shift();draw();
 if(page==='history'&&Date.now()-lastHistory>10000)await history();
 }catch(e){$('connection-text').textContent='连接中断';$('connection-dot').className='dot red';$('start').disabled=true;$('stop').disabled=true;notice('与 NX 的连接已中断。后台采集可能仍在运行；重新打开桌面入口恢复连接。');$('notice').dataset.network='true'}finally{setTimeout(poll,1000)}}
async function action(fn){notice('');try{await fn()}catch(e){notice(e.message)}}
$('start').onclick=()=>action(async()=>{const result=await api('/api/start',{name:$('session-name').value,note:$('session-note').value});$('start').disabled=true;$('operation').hidden=false;$('operation').textContent=result.message});
$('stop').onclick=()=>action(()=>api('/api/stop',{}));
function parameters(){const form=$('parameters');const result={};for(const name of ['fps','chirps','adc_samples','blank_ms','reserve_gib','ramp_us','rx_mask','packet_delay_us'])result[name]=Number(form.elements.namedItem(name).value);result.tx=[Number(form.elements.namedItem('tx').value)];return result}
$('parameters').addEventListener('input',()=>dirty=true);
$('parameters').onsubmit=e=>{e.preventDefault();action(async()=>{const p=await api('/api/profile/save',parameters());dirty=false;populate(p);$('parameter-result').hidden=false;$('parameter-result').textContent='配置已保存并选用。下一次开始时自动完成必要的短采验证。'})};
$('preview').onclick=()=>action(async()=>{if(!$('parameters').reportValidity())return;const p=await api('/api/profile/preview',parameters());timing(p);$('parameter-result').hidden=false;$('parameter-result').textContent='计算完成，尚未保存。'});
$('validate').onclick=()=>action(async()=>{if(dirty)throw Error('请先保存参数，再验证当前配置');await api('/api/validate',{});switchPage('capture')});
const stateNames={capturing:'采集中',capture_stopped:'已停止',capture_failed:'采集异常',capture_partial:'已停止（有质量提示）',interrupted:'异常中断',prepared_no_hardware_started:'已准备',stream_discovery_completed_not_formal_capture:'短采验证',validation_blocked_before_hardware:'验证未通过',preflight_blocked:'预检未通过'};
const reasons={manual_stop_requested:'手动停止',disk_reserve:'磁盘保留空间',receiver_capacity_or_failure:'接收器结束 / 容量条件',worker_error:'采集故障',all_sources_finished:'通道结束',batch_error:'任务异常',manual_stop_before_sensor_start:'启动前取消'};
async function history(){try{const data=await api('/api/history?q='+encodeURIComponent($('search').value)+'&date='+encodeURIComponent($('date').value));lastHistory=Date.now();$('record-count').textContent=`${data.count} 条记录`;$('empty').hidden=!!data.count;$('records').innerHTML=data.items.map(r=>`<tr><td>${esc(r.name)}<small>${esc(r.profile)} · ${esc(r.parameters.fps?num(r.parameters.fps,1)+' Hz':'')}${r.kind==='validation'?' · 验证':''}</small></td><td>${esc(date(r.started_at))}</td><td>${r.duration_s==null?'—':duration(r.duration_s)}</td><td>${gib(r.bytes)} GiB<small>雷达 ${r.bin_count??0} bin · 摄像头 ${r.camera_frames||0} 帧 / ${r.camera_segments||0} 段</small></td><td><span class="pill ${r.quality==='abnormal'?'bad':r.status==='capturing'?'ok':''}">${esc(stateNames[r.status]||r.status)}</span></td><td>${esc(reasons[r.stop_reason]||'—')}<small>${r.quality==='normal'?'质量正常':r.quality==='abnormal'?'存在异常':r.quality==='degraded'?'存在丢帧、帧率不足或通道中断':'暂无质量结论'}${r.boundary_discard_bytes?' · 停止后尾流已丢弃':''}</small>${r.error?'<small>'+esc(r.error)+'</small>':''}</td></tr>`).join('')}catch(e){notice(e.message)}}
$('refresh-history').onclick=history;let searchTimer;$('search').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(history,300)};$('date').onchange=history;
(async()=>{try{token=(await api('/api/bootstrap')).token;poll()}catch(e){notice('暂时无法连接 NX，请重新打开桌面入口。')}})();

function renderCamera(s){
 const info=s.camera||{},cfg=s.acquisition||{},live=info.live||{};const active=s.capture.active||s.operation.busy;
 for(const id of ['source-radar','source-camera','camera-device','camera-mode','camera-segment-seconds'])$(id).disabled=active;
 $('camera-settings').querySelector('button').disabled=active;
 if(!acqDirty){$('source-radar').checked=!!cfg.radar_enabled;$('source-camera').checked=!!cfg.camera_enabled;$('camera-segment-seconds').value=cfg.segment_seconds||10;
 const sig=JSON.stringify((info.devices||[]).map(d=>[d.stable_path,d.modes.map(m=>m.id)]));
 if(sig!==deviceSignature){deviceSignature=sig;$('camera-device').innerHTML=(info.devices||[]).map(d=>`<option value="${esc(d.stable_path)}">${esc(d.name)}</option>`).join('')||'<option value="">等待摄像头接入</option>';}
 if(cfg.camera_device&&Array.from($('camera-device').options).some(o=>o.value===cfg.camera_device))$('camera-device').value=cfg.camera_device;
 rebuildCameraModes(info,cfg.mode_id||'auto');}
 const mode=live.mode||info.selected_mode;const label=mode?`${mode.width}×${mode.height} · ${num(mode.fps,0)} fps · ${mode.fourcc}`:'摄像头未连接';$('camera-mode-label').textContent=cfg.camera_enabled?label:'摄像头未启用';
 const names={recording:'录像中',waiting_for_device:'USB 未识别 · 等待恢复',retrying:'正在恢复录像',starting:'正在检测摄像头',stopping:'正在收尾',stopped:'已停止'};
 const status=cfg.camera_enabled?(names[live.state]||(info.available?'已连接':'未连接')):'未启用';pill('camera-pill',status,live.state==='recording'?'ok':!info.available&&cfg.camera_enabled?'warn':'');
 $('camera-fps').textContent=live.state==='recording'?num(live.fps,1)+' fps':'—';$('camera-frames').textContent=String(live.frames||0);$('camera-rate').textContent=num(live.rate_mib_s||0,2)+' MiB/s';$('camera-segments').textContent=String(live.complete_segments||0);
 $('camera-error').textContent=live.status_message||live.error||info.mode_error||'';
 $('camera-info').textContent=(mode?label+'。':'')+'原生数据直接封装为 MKV，无软件二次编码；拔插会建立新的录像段并记录缺失时段，雷达独立运行。';
}
function rebuildCameraModes(info,wanted){const dev=(info.devices||[]).find(d=>d.stable_path===$('camera-device').value)||info.selected;const html='<option value="auto">自动：最高帧率，同帧率优先较高分辨率</option>'+(dev?.modes||[]).map(m=>`<option value="${esc(m.id)}">${m.width}×${m.height} · ${num(m.fps,1)} fps · ${m.fourcc==='MJPG'?'原生 MJPEG':'无压缩 YUYV'}</option>`).join('');if($('camera-mode').innerHTML!==html)$('camera-mode').innerHTML=html;$('camera-mode').value=wanted;}
function acquisitionValues(){return {radar_enabled:$('source-radar').checked,camera_enabled:$('source-camera').checked,camera_device:$('camera-device').value,mode_id:$('camera-mode').value||'auto',segment_seconds:Number($('camera-segment-seconds').value)}}
async function saveAcquisition(){const result=await api('/api/acquisition/save',acquisitionValues());acqDirty=false;deviceSignature='';$('camera-settings-result').hidden=false;$('camera-settings-result').textContent='采集通道和摄像头设置已保存。'}
$('camera-settings').addEventListener('input',()=>acqDirty=true);
$('camera-device').addEventListener('change',()=>rebuildCameraModes(snapshot.camera,'auto'));
$('camera-settings').onsubmit=e=>{e.preventDefault();action(saveAcquisition)};
for(const id of ['source-radar','source-camera'])$(id).onchange=()=>{acqDirty=true;action(async()=>{try{await saveAcquisition()}catch(e){acqDirty=false;throw e}})};
