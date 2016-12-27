FROM centos:7
MAINTAINER Mark Bonano, mbonano@scholastic.com

# the compiled binary path should be supplied as a build argument
ARG compiled_binary_path

# Upgrading system
RUN yum -y upgrade
RUN yum -y install wget

# Download Oracle Java 8 Archive
RUN wget --no-cookies --no-check-certificate --header "Cookie: gpw_e24=http%3A%2F%2Fwww.oracle.com%2F; oraclelicense=accept-securebackup-cookie" "http://download.oracle.com/otn-pub/java/jdk/8u101-b13/jdk-8u101-linux-x64.tar.gz" -O /opt/jdk-8u101-linux-x64.tar.gz
RUN tar xzf /opt/jdk-8u101-linux-x64.tar.gz -C /opt

# Install Oracle Java 8 with alternatives
RUN alternatives --install /usr/bin/java java /opt/jdk1.8.0_101/bin/java 2
RUN alternatives --install /usr/bin/jar jar /opt/jdk1.8.0_101/bin/jar 2
RUN alternatives --install /usr/bin/javac javac /opt/jdk1.8.0_101/bin/javac 2
RUN alternatives --set jar /opt/jdk1.8.0_101/bin/jar
RUN alternatives --set javac /opt/jdk1.8.0_101/bin/javac

# Configure common environment variables
ENV JAVA_HOME /opt/jdk1.8.0_101
ENV JRE_HOME /opt/jdk1.8.0_101/jre
ENV PATH $PATH:/opt/jdk1.8.0_101/bin:/opt/jdk1.8.0_101/jre/bin

# copy application binary
COPY ${compiled_binary_path} /opt/compile_app

# Define entrypoint
ENTRYPOINT ["java", "-jar", "/opt/compile_app"]

