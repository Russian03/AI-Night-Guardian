Datasets:
* AudioSet: millions of 10s clips extracted from YouTube; it does not have video files, only a .csv file with the videos' IDs and the start and end time of each clip, as well as the assigned classes.
  - URL: https://research.google.com/audioset/download.html
* Coughvid: more than 20000 recordings of coughing sounds.
  - URL: https://zenodo.org/records/4048312
* ESC 50: 2000 5s audios, with special focus on environmental sounds.
  - URL: https://github.com/karolpiczak/esc-50
* FSD50K: more than 50000 audio clips from Freesound with 200 different sound-classes. The audios' length varies between 0.3s and 30s.
  - URL: https://zenodo.org/records/4060432

Scripts:
* audioset_extractor.py: filters the dataset and donwloads only the selected videos.
* coughvid_extractor.py: filters the locally downloaded coughvid dataset.
* esc50_extractor.py: filters the locally downloaded esc50 dataset.
* fsd50k_extractor.py: filters the locally downloaded coughvid dataset.
* UNIFICADOR.py: converts all selected videos by the previous scripts to 16kHz mono format.

Requisites:
* python3
  - os
  - pandas
  - sutil
  - subprocess
* FFmpeg
