// multiple environments can be added by using a pipe delimited string; e.g. alpha.dev.oesinc.dev|bravo.dev.oesinc.dev|127.0.0.1
let environments =
  "{{ .Values.global.site }},{{ .Values.global.domain | default .Values.ingress.domain }}";
let gmsEndpoint = "{{ .Values.global.domain | default .Values.ingress.domain }}";

// target a specific database
db = db.getSiblingDB("settings_api");

// Drop Configurations collection on every run
// This collection is meant to be recreated fresh by the application
try {
  db.Configurations.drop();
  print("Dropped Configurations collection");
} catch (e) {
  print("Failed to drop Configurations collection: " + e);
}

// Drop EnvironmentDetails on every run
try {
  db.EnvironmentDetails.drop();
  print("Dropped EnvironmentDetails collection");
} catch (e) {
  print("Failed to drop EnvironmentDetails collection: " + e);
}

// create a user for the settings_api database
try {
  db.createUser({
    user: {{ required "mongodb.auth.username is required for MongoDB initialization" .Values.mongodb.auth.username | quote }},
    pwd: {{ required "mongodb.auth.password is required for MongoDB initialization" .Values.mongodb.auth.password | quote }},
    roles: [
      {
        role: "readWrite",
        db: "settings_api",
      },
    ],
  });
} catch (e) {
  if (e.code !== 51003) { // User already exists error code
    throw e;
  }
  print("MongoDB application user already exists");
}

// Create AuthSettings document for gms-api
// Note: gms-api queries for this document with environmentId='default' during startup
// This document MUST contain full OAuth URIs for the application to work correctly
let authSettings = {
  environmentId: "default",
  client_id: "gms",
  access_token: `https://keycloak.${gmsEndpoint}/realms/oes/protocol/openid-connect/token`,
  authorization_uri: `https://keycloak.${gmsEndpoint}/realms/oes/protocol/openid-connect/auth`,
  logout_uri: `https://keycloak.${gmsEndpoint}/realms/oes/protocol/openid-connect/logout`,
  authorization_issuer: `https://keycloak.${gmsEndpoint}/realms/oes`,
  authorization_jwks_uri: `https://keycloak.${gmsEndpoint}/realms/oes/protocol/openid-connect/certs`,
  hmi_audience: "openfmb-hmi",
  scopes: ["openid", "profile", "email"],
  nats_auth: {{ dig "nats-auth-svc" "enabled" false .Values.global }}
};

// Create in BOTH AuthSettings (capital) and authsettings (lowercase) collections
// The app may look in either collection depending on version
// Idempotent: Only insert if document doesn't exist
try {
  if (db.AuthSettings.countDocuments({ environmentId: 'default' }) === 0) {
    db.AuthSettings.insertOne(authSettings);
    print("Created AuthSettings (capital) document with environmentId='default'");
  } else {
    print("AuthSettings (capital) document already exists, skipping");
  }

  if (db.authsettings.countDocuments({ environmentId: 'default' }) === 0) {
    db.authsettings.insertOne(authSettings);
    print("Created authsettings (lowercase) document with environmentId='default'");
  } else {
    print("authsettings (lowercase) document already exists, skipping");
  }
} catch (e) {
  print("Error creating authsettings: " + e);
  throw e;
}
  
let environmentDetails = [];
let endpoints = [];
let menuItems = [];

let environmentArray = environments.split('|');
for (const env of environmentArray) {
  let envName = '';
  let endpoint = '';
  let environment = env.split(',');
  let envId = ObjectId().toString();

  if (environment.length === 1) {
    envName = environment[0].trim();
    endpoint = environment[0].trim();
  } else {
    envName = environment[0].trim();
    endpoint = environment[1].trim();
  }

  if (!envName && !endpoint) {
    continue;
  }

  environmentDetails.push({
    environmentId: envId,
    name: envName
  });

  endpoints.push({
    environmentId: envId,
    name: 'nats',
    uri: `wss://nats.${endpoint}`
  },
  {
    environmentId: envId,
    name: 'overpass_api',
    uri: `https://${endpoint}:12346/api`
  },
  {
    environmentId: envId,
    name: 'grpc',
    // gRPC-web is exposed via the grpc.<domain> ingress host (envoy on
    // historian-svc), not a raw port on the base domain. Mirrors the nats.<domain>
    // pattern above; `https://${endpoint}:5051` is unreachable from the browser.
    uri: `https://grpc.${endpoint}`
  });

  menuItems.push(
    {
      title: "Home",
      group: "",
      company: "",
      icon: "mdi-home",
      link: `https://${gmsEndpoint}`,
      src: "",
      roles: ["admin", "user"],
      external: true,
      environmentId: `${envId}`,
      index: 0,
    },
    {
      title: "GIS",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-map",
      link: `https://gis.${gmsEndpoint}`,
      src: "/images/gis.png",
      roles: ["GIS"],
      external: true,
      environmentId: `${envId}`,
      index: 1
    },
    {
      title: "One Line",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-file-tree",
      link: `https://oneline.${gmsEndpoint}`,
      src: "/images/one-line.png",
      roles: ["OneLine"],
      external: true,
      environmentId: `${envId}`,
      index: 2
    },
    {
      title: "Message Inspector",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-format-list-numbered",
      link: `https://openfmb.${gmsEndpoint}`,
      src: "/images/openfmb-data-viewer.png",
      roles: ["OpenFMB"],
      external: true,
      environmentId: `${envId}`,
      index: 3
    },
    {
      title: "Inventory",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-google-spreadsheet",
      link: `https://inventory.${gmsEndpoint}`,
      src: "/images/inventory.png",
      roles: ["Inventory"],
      external: true,
      environmentId: `${envId}`,
      index: 5
    },
    {
      title: "Event Viewer",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-format-list-bulleted",
      link: `https://eventviewer.${gmsEndpoint}`,
      src: "/images/events.png",
      roles: ["EventView"],
      external: true,
      environmentId: `${envId}`,
      index: 6
    },
    {
      title: "Historian",
      group: "Service Apps",
      company: "OES",
      icon: "mdi-database-search",
      link: `https://historian.${gmsEndpoint}`,
      src: "/images/historian.png",
      roles: ["Historian"],
      external: true,
      environmentId: `${envId}`,
      index: 7
    },
    {
      title: "OpenFMB Event Creator",
      group: "Service Apps",
      company: "OES",
      icon: "mdi-pencil-ruler",
      link: `https://openfmbeventcreator.${gmsEndpoint}`,
      src: "/images/event-rules.png",
      roles: ["EventRuleView"],
      external: true,
      environmentId: `${envId}`,
      index: 8
    },
    // {
    //   title: "CIM Import",
    //   group: "Admin Tools",
    //   company: "OES",
    //   disabled: true,
    //   icon: "mdi-upload",
    //   link: `https://cim.${gmsEndpoint}`,
    //   src: "/images/cim-import.png",
    //   roles: ["EventRuleView"],
    //   environmentId: `${envId}`,
    //   index: 9
    // },
    // {
    //   title: "IMS",
    //   group: "Admin Tools",
    //   company: "OES",
    //   disabled: true,
    //   icon: "mdi-rocket",
    //   link: `http://${gmsEndpoint}:5001`,
    //   src: "/images/ims.png",
    //   roles: ["IMS"],
    //   external: true,
    //   port: 5001,
    //   environmentId: `${envId}`,
    //   index: 10
    // },
    {
      title: "OpenDSO Docs",
      group: "Admin Tools",
      company: "OES",
      icon: "mdi-book-open",
      link: `https://docs.openenergysolutions.com/`,
      src: "/images/documentation.png",
      roles: ["Docs"],
      external: true,
      environmentId: `${envId}`,
      index: 11
    },
    {
      title: "Operations Dashboard",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-view-module",
      link: `https://dataviewer.${gmsEndpoint}`,
      src: "/images/data-viewer.png",
      roles: ["DataViewer"],
      external: true,
      environmentId: `${envId}`,
      index: 12
    },
    {
      title: "DER Dispatch",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-transmission-tower-import",
      link: `https://derdispatch.${gmsEndpoint}`,
      src: "/images/control-panel.png",
      roles: ["DerDispatch"],
      external: true,
      environmentId: `${envId}`,
      index: 13
    },
    {
      title: "Device Details",
      group: "hidden",
      company: "OES",
      icon: "",
      link: `https://device.${gmsEndpoint}`,
      src: "",
      roles: ["DeviceDetails"],
      external: true,
      environmentId: `${envId}`,
      index: 14
    },
    {
      title: "Automated ESS Testing",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-battery-check",
      link: `https://esstesting.${gmsEndpoint}`,
      src: "/images/battery-test.png",
      roles: ["EssTesting"],
      external: true,
      environmentId: `${envId}`,
      index: 15,
    },
    {
      title: "Schedule Dispatch",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-calendar-today",
      link: `https://scheduledispatch.${gmsEndpoint}`,
      src: "/images/edo-adr.png",
      roles: ["ScheduleDispatch"],
      external: true,
      environmentId: `${envId}`,
      index: 16,
    },
    {
      title: "Asset Health",
      group: "Operational Apps",
      company: "OES",
      icon: "mdi-shield-check",
      link: `https://ahs.${gmsEndpoint}`,
      src: "/images/ahs.png",
      roles: ["AHS"],
      external: true,
      environmentId: `${envId}`,
      index: 17,
    },
  );
}

// Idempotent: Only insert environment details if they don't exist
if (environmentDetails && environmentDetails.length) {
  for (const envDetail of environmentDetails) {
    if (db.EnvironmentDetails.countDocuments({ environmentId: envDetail.environmentId }) === 0) {
      db.EnvironmentDetails.insertOne(envDetail);
      print(`Created EnvironmentDetails for ${envDetail.name}`);
    } else {
      print(`EnvironmentDetails for ${envDetail.name} already exists, skipping`);
    }
  }
}

// Idempotent: Only insert endpoints if they don't exist
if (endpoints && endpoints.length) {
  for (const endpoint of endpoints) {
    if (db.EndpointSettings.countDocuments({ environmentId: endpoint.environmentId, name: endpoint.name }) === 0) {
      db.EndpointSettings.insertOne(endpoint);
      print(`Created EndpointSettings for ${endpoint.name}`);
    } else {
      print(`EndpointSettings for ${endpoint.name} already exists, skipping`);
    }
  }
}

// Idempotent: Only insert menu items if they don't exist
if (menuItems && menuItems.length) {
  for (const menuItem of menuItems) {
    if (db.application_settings.countDocuments({ title: menuItem.title, environmentId: menuItem.environmentId }) === 0) {
      db.application_settings.insertOne(menuItem);
      print(`Created menu item for ${menuItem.title}`);
    } else {
      print(`Menu item for ${menuItem.title} already exists, skipping`);
    }
  }
}
