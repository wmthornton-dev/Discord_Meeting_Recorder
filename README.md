This is a simple Bash program (optimized for Linux distributions but capable of working on FreeBSD) that allows users to record
Discord voice chats and meetings, including audio and video using OBS Studio and Pipewire/PulseAudio.

The script itself is written with included Python code to act as an internal audio cable and setup the connection from Discord
to OBS Studio. 

The script and OBS Studio must be running at the same time in order for this script to work. 

Users must setup a scene that only captures the Discord window and must also setup a PulseAudio connection using the Discord_Meeting_Recorder
option that is created when the script is running. 

See script comments for specific usage instructions.