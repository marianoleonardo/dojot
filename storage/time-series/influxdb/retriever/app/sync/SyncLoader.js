/* eslint-disable no-await-in-loop */
const cron = require('node-cron');

const {
  ConfigManager: { getConfig },
  LocalPersistence: { InputPersister, InputPersisterArgs },
} = require('@dojot/microservice-sdk');

const { sync } = getConfig('RETRIEVER');

const {
  Logger,
} = require('@dojot/microservice-sdk');


// Promissify functions.


const logger = new Logger('influxdb-retriever:sync');

// Config InputPersister
const INPUT_CONFIG = {
  levels: [
    {
      type: 'static',
      name: 'tenants',
      options: {
        keyEncoding: 'utf8',
        valueEncoding: 'json',
      },
    },
    {
      type: 'dynamic',
      source: 'service',
      options: {
        keyEncoding: 'utf8',
        valueEncoding: 'bool',
      },
    },
  ],
  frames: [
    {
      level: 0,
      pair: {
        key: {
          type: 'dynamic',
          source: 'tenant.id',
        },
        value: {
          type: 'dynamic',
          source: 'tenant',
        },
      },
    },
    {
      level: 1,
      pair: {
        key: {
          type: 'dynamic',
          source: 'device',
        },
        value: {
          type: 'static',
          source: true,
        },
      },
    },
  ],
};

class SyncLoader {
  /**
   * Synchronizes with other services to ensure consistency
   *
   * @param {*} localPersistence the persister manager object
   * @param {*} tenantService the tenant service object
   * @param {*} deviceDataRepository the device service object
   */
  constructor(localPersistence, tenantService, deviceDataRepository, retrieverConsumer) {
    this.localPersistence = localPersistence;
    this.tenantService = tenantService;
    this.deviceDataRepository = deviceDataRepository;
    this.inputPersister = new InputPersister(localPersistence, INPUT_CONFIG);
    this.retrieverConsumer = retrieverConsumer;
  }

  /**
   * Runs first synchronization and schedules data synchronization with other services
   */
  async init() {
    try {
      // Initializes Sync Services
      await this.localPersistence.init();
      // First synchronization
      logger.debug('First synchronization..');
      await this.load();
      // Kafka
      try {
        // await this.retrieverConsumer.init();
      } catch (error) {
        logger.debug('It was not possible to init kafka');
        logger.error(error);
      }
      // Cron
      try {
        logger.info('Data sync scheduled');
        cron.schedule(sync['cron.expression'], () => {
          // this.retrieverConsumer.unregisterCallbacks();
          logger.debug('Start data synchronization with other services');
          this.load().finally(() => {
            // this.retrieverConsumer.resume();
          });
        });
      } catch (error) {
        logger.debug('It was not possible to schedule synchronization');
        logger.error(error);
      }
    } catch (error) {
      logger.error(error);
    }
  }

  /**
   * Syncronizes and loads data
   */
  async load() {
    // Search for data in an API
    try {
      logger.info('Synchronizing tenant and device data with other services.');
      await this.tenantService.loadTenants();

      // eslint-disable-next-line no-restricted-syntax
      for (const tenant of this.tenantService.tenants) {
        // Sync and load devices
        try {
          await this.loadDevices(tenant);
        } catch (error) {
          logger.debug(`It was not possible to retrieve ${tenant} devices with device manager.`);
          logger.error(error.message);
        }
      }
    // Search for data in the database
    } catch (tenantServiceError) {
      logger.error(tenantServiceError);
    }
  }

  /**
   * Syncronizes and loads devices
   *
   */
  async loadDevices(tenant) {
    logger.info('Sync device-manager.');
    const devices = await this.deviceDataRepository.getDevices(tenant);

    try {
      logger.debug(`Clean up ${tenant.id} sublevel`);
      await this.localPersistence.clear(tenant.id);
    } catch (error) {
      logger.error(error);
    }

    // eslint-disable-next-line no-restricted-syntax
    for (const device of devices) {
      // Write devices
      await this.inputPersister.dispatch(
        { device, service: tenant.id }, InputPersisterArgs.INSERT_OPERATION,
      );
    }
  }
}

module.exports = SyncLoader;
