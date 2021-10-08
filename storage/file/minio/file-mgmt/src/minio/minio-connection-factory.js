const Minio = require('minio');
const { promisify } = require('util');

module.exports = (configMinio) => {
  const minioClient = new Minio.Client({
    endPoint: configMinio.host,
    port: configMinio.port,
    useSSL: configMinio.ssl,
    accessKey: configMinio.accessKey,
    secretKey: configMinio.secretKey,
  });

  minioClient.makeBucket = promisify(minioClient.makeBucket);
  minioClient.removeBucket = promisify(minioClient.removeBucket);
  minioClient.putObject = promisify(minioClient.putObject);
  minioClient.bucketExists = promisify(minioClient.bucketExists);

  return minioClient;
};
