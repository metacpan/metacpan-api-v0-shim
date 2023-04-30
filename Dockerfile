FROM metacpan/metacpan-base:latest

WORKDIR /app
COPY . .

RUN cpm install -g
EXPOSE 5006
CMD [ "plackup", "-I", "lib", "-p", "5006", "app.psgi" ]
