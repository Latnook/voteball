# Jenkins controller with plugins baked in.
#
# WHY BAKED: this controller is disposable and restarts roughly daily -- the node group is 100% Spot
# and ASG history showed three reclaims in 84 hours (design doc section 2). The official chart's
# default is to download plugins from updates.jenkins.io at every startup, which at that restart rate
# is both slow and a hard dependency on a third-party site being up. Baking them makes startup a few
# seconds and needs no internet.
#
# ADDING A PLUGIN: edit ci/jenkins/plugins.txt, then rebuild and push this image with
# ./scripts/build-push-ecr.sh jenkins. Editing the file alone changes nothing -- the running
# controller uses the image, not the file.
# PINNED BY VERSION *AND* DIGEST (2026-08-23, Task 4 review finding P2). This was
# `FROM jenkins/jenkins:lts-jdk21`, a tag that moves whenever a new LTS ships -- so rebuilding this
# same git commit six weeks from now produced a different controller, and nothing recorded which one
# you got. The review found the drift already present in this repo's own evidence: the Helm release
# reports app version 2.568.1 while the controller's plugin inventory reported 2.568.2.
#
# The version tag and the digest resolve to the same image today (verified 2026-10-01), and both are
# written on purpose: the digest is what actually pins, and the version is what makes the pin
# readable to a human deciding whether it is stale. A bare digest tells you nothing about how far
# behind you are.
#
# JAVA 25, not 21 (since 2026-10-01): Jenkins drops Java 21 on or after 2027-09-30 and has supported
# 25 since LTS 2.541.1. The -jdk21 tag of the same release still exists if this ever needs reverting.
#
# BUMPING IT: change both halves together, then regenerate the plugin lock in the SAME commit with
# ./scripts/jenkins/lock-plugins.sh -- plugin resolution depends on the core version, so a new base
# with an old lock is a combination that was never tested.
FROM jenkins/jenkins:2.580.1-jdk25@sha256:42fc298cdafa2683dddde9a7ccdce4058f771b1ec56c2423dbfca82f010a455f

# Installs the RESOLVED LOCK, not the human list. plugins.txt names top-level plugins and no versions
# -- it is where the justifications live and is meant to stay readable. plugins.lock.txt is generated
# from it by ./scripts/jenkins/lock-plugins.sh and names every plugin, transitive dependencies
# included, at an exact version. Installing the lock is what makes two builds of this commit produce
# the same controller; installing plugins.txt would re-resolve "latest compatible" at build time and
# give you whatever shipped that week.
#
# --verbose still records what was installed in the build log, but the log is no longer the only
# record -- plugins.lock.txt is committed, which is the point.
COPY --chown=jenkins:jenkins plugins.txt      /usr/share/jenkins/ref/plugins.txt
COPY --chown=jenkins:jenkins plugins.lock.txt /usr/share/jenkins/ref/plugins.lock.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.lock.txt --verbose \
 && jenkins-plugin-cli --list

# EVERY BAKED PLUGIN IS RENAMED *.jpi.override (2026-10-21), so the entrypoint copies it over
# JENKINS_HOME on every boot instead of deciding by version. JENKINS_HOME is an EFS volume that
# survives restarts, so the entrypoint finds last image's plugins already there and copies a baked
# one only if its versionLT() says the image's is newer -- and that comparison is wrong for some
# real version pairs. Observed on the 2026-10-21 bump: "9.11.1-226.vff833a_e4c58e" sorted OLDER
# than "9.11-224.v369c884f7a_a_b_" (it compares 1 against 224), so the cluster booted the new image
# still loading the old asm-api, with nothing in the Jenkins log -- only a SKIPPED line in
# $JENKINS_HOME/copy_reference_file.log. With the suffix the lock is what runs, downgrades included,
# which is what plugins.lock.txt already claims. PLUGINS_FORCE_UPGRADE does not cover this case: it
# only applies to a plugin someone upgraded by hand through the UI. The log keeps printing
# "SKIPPED ... is older than installed" for a forced plugin, then copies it anyway -- check the
# installed .jpi's manifest, not that log (docs/maintenance.md).
RUN cd /usr/share/jenkins/ref/plugins \
 && for f in *.jpi; do mv "$f" "$f.override"; done

# JCasC is NOT baked into this image, deliberately (decided 2026-07-30). The Helm release supplies
# ci/jenkins/jenkins.yaml through a Terraform-managed ConfigMap, so a second copy here would be a
# second source of truth that can disagree with it whenever the image and the chart are built from
# different commits.
#
# It would also not work. JENKINS_HOME (/var/jenkins_home) is a volume mounted over the image's
# directory -- an emptyDir until 2026-08-04, an EFS PersistentVolumeClaim since -- so anything COPYed
# under that path is MASKED in the cluster while still being visible to `docker run`: local testing
# passes and the cluster silently disagrees. The plugins above survive only because
# jenkins-plugin-cli writes them to /usr/share/jenkins/ref/, which the entrypoint copies INTO
# JENKINS_HOME at boot (see the .override note above for why that copy is forced).

# Skip the setup wizard: JCasC owns this configuration, and the wizard would leave the 94-plugin
# "install suggested" set the plugins.txt header exists to replace.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

USER jenkins
