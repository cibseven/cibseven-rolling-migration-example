package com.example.telco;

import java.net.InetAddress;
import java.util.logging.Logger;
import org.camunda.bpm.engine.ProcessEngine;
import org.camunda.bpm.engine.delegate.DelegateExecution;
import org.camunda.bpm.engine.impl.util.ProductPropertiesUtil;

/**
 * Records on which cluster node and on which engine an activity was executed:
 * process variable "&lt;activityId&gt;_executedBy" = "&lt;node&gt; / &lt;engine&gt;" plus one log line.
 */
public final class ExecutionTrace {

  private static final Logger LOG = Logger.getLogger("com.example.telco.NumberPorting");

  /** JBoss node name, falls back to the host name. */
  public static final String NODE = resolveNode();

  /** Product and version of the engine that is actually running, e.g. "Camunda 7.24.0". */
  public static final String ENGINE = resolveEngine();

  private ExecutionTrace() {
  }

  public static void record(DelegateExecution execution) {
    String activityId = execution.getCurrentActivityId();
    execution.setVariable(activityId + "_executedBy", NODE + " / " + ENGINE);
    LOG.info(String.format("[%s] activity=%s engine=%s pi=%s businessKey=%s scenario=%s",
        NODE, activityId, ENGINE, execution.getProcessInstanceId(),
        execution.getProcessBusinessKey(), scenario(execution)));
  }

  /** Read on every call, so an operator can change the variable and retry an incident. */
  public static String scenario(DelegateExecution execution) {
    Object scenario = execution.getVariable("scenario");
    return scenario == null ? "success" : scenario.toString();
  }

  private static String resolveNode() {
    String node = System.getProperty("jboss.node.name");
    if (node != null && !node.isBlank()) {
      return node;
    }
    try {
      return InetAddress.getLocalHost().getHostName();
    } catch (Exception e) {
      return "unknown-node";
    }
  }

  private static String resolveEngine() {
    // The package of the engine API tells the product, the engine's product-info the version.
    String product = ProcessEngine.class.getPackageName().startsWith("org.cibseven") ? "CIB seven" : "Camunda";
    String version;
    try {
      version = ProductPropertiesUtil.getProductVersion();
    } catch (RuntimeException | LinkageError e) {
      version = ProcessEngine.class.getPackage().getImplementationVersion();
    }
    return product + " " + version;
  }
}
