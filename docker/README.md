Step 1: Build the docker image with Dockerfile customized by Lingjun. You can rename the name of the docker image.

Step 2: Run the docker container with run.sh. You can change the path and rename the docker container in the script.

Step 3: Inside the docker container, find the pre-generated build_all.sh file under /usr/local/bin/build_all.sh. Subsitute it with the bug-free(should be, otherwise please ask Claude Code) version, build_all.sh under this folder. Then run it to build everything.