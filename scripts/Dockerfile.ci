FROM eclipse-mosquitto

COPY mosquitto/config /mosquitto/config
COPY mosquitto/certs /mosquitto/certs

EXPOSE 1883
EXPOSE 8883
EXPOSE 8080
EXPOSE 8081

ENTRYPOINT ["/usr/sbin/mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]