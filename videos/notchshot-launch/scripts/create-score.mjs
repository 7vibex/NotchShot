// Original deterministic score for this video. No sampled/reference music.
import fs from 'node:fs';
const sr=44100, duration=69, n=Math.ceil(sr*duration), left=new Float32Array(n), right=new Float32Array(n);
const beat=60/112, midi=m=>440*2**((m-69)/12);
let seed=194716; const rand=()=>{seed=(seed*1664525+1013904223)>>>0;return seed/4294967296*2-1;};
function put(start,len,fn,pan=0){ const base=Math.floor(start*sr), count=Math.floor(len*sr);for(let j=0;j<count&&base+j<n;j++){if(base+j<0)continue;const v=fn(j/sr,j);left[base+j]+=v*Math.sqrt((1-pan)/2);right[base+j]+=v*Math.sqrt((1+pan)/2);}}
function pluck(t,m,amp,pan){let f=midi(m);put(t,1.8,(s)=>amp*(1-Math.exp(-s*250))*Math.exp(-s*3.6)*(Math.sin(2*Math.PI*f*s)+.28*Math.sin(2*Math.PI*f*2*s)+.09*Math.sin(2*Math.PI*f*3*s)),pan);}
const chords=[[57,60,64,67],[53,57,60,64],[48,55,59,62],[55,59,62,65]];
for(let bar=0;bar<32;bar++){
 const at=bar*beat*4;if(at>66)break; const c=chords[bar%4], level=bar<3?.65:bar>27?.65:1;
 // Soft extended chord bed with slow envelope.
 c.forEach((m,k)=>put(at,beat*4+.8,s=>.025*level*Math.min(1,s/.35)*Math.exp(-s*.65)*(Math.sin(2*Math.PI*midi(m+12)*s)+.15*Math.sin(2*Math.PI*midi(m+12)*1.003*s)),(k-1.5)*.3));
 for(let step=0;step<8;step++){const seq=[0,2,1,3,2,1,3,2];pluck(at+step*beat/2,c[seq[step]]+24,.078*level,step%2?.3:-.3);}
 put(at,beat*3.6,s=>.075*level*(1-Math.exp(-s*35))*Math.exp(-s*1.8)*Math.sin(2*Math.PI*midi(c[0]-12)*s));
 if(bar>=2&&bar<29){
  for(let b=0;b<4;b++){
   const t=at+b*beat;
   put(t,.28,s=>.14*Math.exp(-s*18)*Math.sin(2*Math.PI*(49*s+1.3*(1-Math.exp(-s*32)))));
   if(b===1||b===3)put(t,.13,s=>.038*rand()*Math.exp(-s*32));
   for(let h=0;h<2;h++)put(t+h*beat/2,.055,s=>.016*rand()*Math.exp(-s*95),h?.5:-.5);
  }
 }
}
// A final, resolved chord under the end card.
[57,60,64,69,76].forEach((m,i)=>pluck(64.5+i*.045,m+12,.075,(i-2)*.16));
// Small stereo echoes: baked during score creation, never wall-clock driven.
const d=Math.floor(beat*.75*sr);for(let i=n-1;i>=d;i--){left[i]+=.18*right[i-d];right[i]+=.16*left[i-d];}
let peak=0;for(let i=0;i<n;i++){const t=i/sr,fade=Math.min(1,t/.3,Math.max(0,(duration-t)/2.3));left[i]*=fade;right[i]*=fade;peak=Math.max(peak,Math.abs(left[i]),Math.abs(right[i]));}
const out=Buffer.alloc(44+n*4);out.write('RIFF');out.writeUInt32LE(out.length-8,4);out.write('WAVEfmt ',8);out.writeUInt32LE(16,16);out.writeUInt16LE(1,20);out.writeUInt16LE(2,22);out.writeUInt32LE(sr,24);out.writeUInt32LE(sr*4,28);out.writeUInt16LE(4,32);out.writeUInt16LE(16,34);out.write('data',36);out.writeUInt32LE(n*4,40);
const gain=.63/peak;for(let i=0;i<n;i++){out.writeInt16LE(Math.round(left[i]*gain*32767),44+i*4);out.writeInt16LE(Math.round(right[i]*gain*32767),46+i*4);}fs.writeFileSync('assets/music.wav',out);console.log(JSON.stringify({duration,sampleRate:sr,channels:2,peak:.63,bytes:out.length,provenance:'original deterministic additive synthesis'}));
