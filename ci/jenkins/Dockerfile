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
FROM jenkins/jenkins:lts-jdk21

# jenkins-plugin-cli resolves dependencies itself, which is why plugins.txt lists only top-level
# entries. --verbose records the resolved version of every plugin in the build log: that log IS the
# record of what this tag contains, since the file names no versions.
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --verbose \
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
