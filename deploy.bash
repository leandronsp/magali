#!/bin/bash

USER=home/leandronsp
DIR=magali
TARGET=$USER/$DIR
PROGRAM=server

scp app/* ubuntu:/$TARGET/
ssh ubuntu "nasm -f elf64 -g -o /$TARGET/$PROGRAM.o /$TARGET/$PROGRAM.asm && ld -o /$TARGET/$PROGRAM /$TARGET/$PROGRAM.o"
