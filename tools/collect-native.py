"""Collect read-only native inspection output from an app you supply. macOS only."""
import argparse,subprocess,sys
from pathlib import Path
cli=argparse.ArgumentParser(description=__doc__)
cli.add_argument('--app',default='/Applications/Typora.app')
cli.add_argument('--output',default='.local/native')
args=cli.parse_args();app=Path(args.app).resolve();out=Path(args.output).resolve();out.mkdir(parents=True,exist_ok=True)
if sys.platform!='darwin':cli.error('Native collection requires macOS otool/nm.')
for label,relative in [('main','Contents/MacOS/Typora'),('lib','Contents/Frameworks/libTypora.dylib')]:
 target=app/relative
 if not target.is_file():
  print(f'Skipped missing target: {target}');continue
 for kind,command in [('objc',['otool','-arch','arm64','-ov',str(target)]),('disassembly',['otool','-arch','arm64','-tvV',str(target)]),('symbols',['nm','-arch','arm64','-n',str(target)])]:
  with (out/f'native-{label}-{kind}.txt').open('w') as stream:
   subprocess.run(command,stdout=stream,check=True)
print(f'Local inspection output: {out}')
