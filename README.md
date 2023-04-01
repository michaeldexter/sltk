## The Storage Lifecycle Tool Kit (SLTK)
A BETA* cross-platform ZFS-oriented storage lifecycle tool kit for FreeBSD, illumos, and GNU/Linux targeting "cradle to grave" storage management

* Warning! NB! OBS! Some of these tools are designed destroy data. Understand them before using them.

Components:

```
functions.incl		Functions Library
part.sh			Partitioning Script
depart.sh		De-partitioning Script
pool.sh			zpool Creation Script
bench.sh		Benchmarking Script
sample.fio		Sample Fio Profile
profile-truenas.txt	TrueNAS zpool profile
profile-proxmox.txt	Proxmox zpool profile
```

Missing features:

zpool disk replacement and non-data vdev handling, i.e. SLOG
sanitize.sh device sanitization script
inventory.sh devicce inventory script
'zpt', the cross-platform GPT partitioner
f_part custom illumos and Linux partitioning (currently relies on zpool)
Proper dRAID support

Example usage on GNU/Linux:

```
echo Removing partitioning
sh depart.sh -d "sdc sdd sde sdf sdg sdh"

echo Creating RAIDZ2 pool tank with six disks per single vdev and properties-proxmox-lcd.txt profile
sh pool.sh -d "sdc sdd sde sdf sdg sdh" -m raw -r raidz2 -v 6 \
	-z tank -p properties-proxmox-lcd.txt -y || exit 1
zpool status

echo Benchmarking /tank with sample.fio
sh bench.sh -p /tank -f sample.fio

echo Destroying tank
zpool destroy tank
```

This can be re-run with different Fio and pool profiles.
