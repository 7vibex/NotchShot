#!/usr/bin/env python3
"""Generate disposable recovery fixtures with installed ffmpeg/ffprobe. Pass a NEW output directory."""
import pathlib,subprocess,os,signal,time,json,sys
p=pathlib.Path(sys.argv[1])
p.mkdir(mode=0o700)  # Refuse to overwrite an existing directory.
base=['ffmpeg','-v','error','-re','-f','lavfi','-i','testsrc2=size=320x180:rate=15','-re','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-c:v','libx264','-preset','ultrafast','-g','15','-c:a','aac','-movflags','frag_keyframe+empty_moov+default_base_moof']
with (p/'writer.log').open('w') as log:
 child=subprocess.Popen([*base,'-t','60',str(p/'interrupted.mp4')],stderr=log,start_new_session=True)
 time.sleep(5)
 os.killpg(child.pid,signal.SIGKILL);child.wait()
 print('Killed only the isolated fragment writer after five seconds.',flush=True)
 start=time.monotonic()
 subprocess.run([*base,'-t','120',str(p/'endurance.mp4')],stderr=log,check=True,timeout=150)
 print('Continuous writer completed in',round(time.monotonic()-start,2),'seconds.',flush=True)
results={}
for name in ['interrupted','endurance']:
 results[name]=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration,size:stream=codec_name,codec_type,nb_frames','-of','json',str(p/(name+'.mp4'))],text=True))
(p/'media-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results))
