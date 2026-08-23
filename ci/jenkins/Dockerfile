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
# The version tag and the digest resolve to the same image today (verified 2026-08-23), and both are
# written on purpose: the digest is what actually pins, and the version is what makes the pin
# readable to a human deciding whether it is stale. A bare digest tells you nothing about how far
# behind you are.
#
# BUMPING IT: change both halves together, then regenerate the plugin lock in the SAME commit with
# ./scripts/jenkins/lock-plugins.sh -- plugin resolution depends on the core version, so a new base
# with an old lock is a combination that was never tested.
FROM jenkins/jenkins:2.568.2-jdk21@sha256:8547df3b0db2803d158ecc9499207a056bb30c23fddc18bb5b4a4dc14e77dd09

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

# JCasC is NOT baked into this image, deliberately (decided 2026-07-30). The Helm release supplies
# ci/jenkins/jenkins.yaml through controller.JCasC.configScripts, so a second copy here would be a
# second source of truth that can disagree with it whenever the image and the chart are built from
# different commits.
#
# It would also not work. `persistence.enabled: false` mounts an emptyDir over /var/jenkins_home, so
# anything COPYed under that path is MASKED in the cluster while still being visible to `docker run`
# -- local testing passes and the cluster silently disagrees. The plugins above survive only because
# jenkins-plugin-cli writes them to /usr/share/jenkins/ref/, which the entrypoint copies INTO
# JENKINS_HOME at boot.

# Skip the setup wizard: JCasC owns this configuration, and the wizard would leave the 94-plugin
# "install suggested" set the plugins.txt header exists to replace.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

USER jenkins
