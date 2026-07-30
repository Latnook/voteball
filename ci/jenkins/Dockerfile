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

# JCasC is read from here at every boot. The chart also mounts its own config; this copy is the
# fallback that makes the image self-describing and lets `docker run` smoke-test it offline.
COPY --chown=jenkins:jenkins jenkins.yaml /var/jenkins_home/casc_configs/jenkins.yaml
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs

# Skip the setup wizard: JCasC owns this configuration, and the wizard would leave the 94-plugin
# "install suggested" set the plugins.txt header exists to replace.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

USER jenkins
