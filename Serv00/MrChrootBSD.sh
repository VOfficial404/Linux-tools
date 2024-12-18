#!/bin/bash

git clone https://github.com/nrootconauto/MrChrootBSD.git

cd MrChrootBSD

wget https://download.freebsd.org/releases/amd64/14.1-RELEASE/base.txz

wget https://download.freebsd.org/releases/amd64/14.1-RELEASE/lib32.txz

mkdir chroot

cd chroot 

tar xvf ../base.txz

tar xvf ../lib32.txz

cd ..

cmake .

make

cp /etc/resolv.conf chroot/etc

./mrchroot chroot /bin/sh
