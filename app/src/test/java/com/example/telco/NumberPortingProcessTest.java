package com.example.telco;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.camunda.bpm.engine.HistoryService;
import org.camunda.bpm.engine.ManagementService;
import org.camunda.bpm.engine.ProcessEngineConfiguration;
import org.camunda.bpm.engine.RuntimeService;
import org.camunda.bpm.engine.runtime.Incident;
import org.camunda.bpm.engine.runtime.Job;
import org.camunda.bpm.engine.runtime.ProcessInstance;
import org.camunda.bpm.engine.test.Deployment;
import org.camunda.bpm.engine.test.junit5.ProcessEngineExtension;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.RegisterExtension;

/** Runs the number-porting process on an in-memory engine (H2, job executor off, jobs executed by the test). */
@Deployment(resources = "numberPorting.bpmn")
class NumberPortingProcessTest {

  @RegisterExtension
  static ProcessEngineExtension extension = ProcessEngineExtension.builder()
      .useProcessEngine(ProcessEngineConfiguration.createStandaloneInMemProcessEngineConfiguration()
          .setJdbcUrl("jdbc:h2:mem:number-porting;DB_CLOSE_DELAY=-1")
          .setJobExecutorActivate(false)
          .setHistory(ProcessEngineConfiguration.HISTORY_FULL)
          .buildProcessEngine())
      .build();

  RuntimeService runtime = extension.getRuntimeService();
  ManagementService management = extension.getManagementService();
  HistoryService history = extension.getHistoryService();

  @BeforeAll
  static void printEngine() {
    System.out.println("Engine under test: " + ExecutionTrace.ENGINE);
  }

  @Test
  void successPath() {
    ProcessInstance pi = start("success");

    executeJob(pi, "provisionHss");
    Job timer = management.createJobQuery().processInstanceId(pi.getId()).timers().singleResult();
    assertEquals("PT30S", runtime.getVariable(pi.getId(), "waitDuration"), "default wait duration");
    assertTrue(timer.getDuedate().getTime() - System.currentTimeMillis() > 20_000, "timer due in ~30 s");
    executeJob(pi, "waitForDonorWindow");
    executeJob(pi, "activateNumber");

    assertEnded(pi, "numberPorted");
    for (String activity : List.of("validateRequest", "provisionHss", "activateNumber")) {
      assertTrue(historicVariable(pi, activity + "_executedBy").toString().endsWith(" / " + ExecutionTrace.ENGINE),
          activity + " records node and engine");
    }
  }

  @Test
  void rejectPath() {
    ProcessInstance pi = start("reject");

    assertEnded(pi, "portingRejected");
    assertEquals(true, historicVariable(pi, "customerNotified"));
    assertTrue(historicVariable(pi, "notifyRejected_executedBy").toString().contains(ExecutionTrace.ENGINE));
    assertNull(history.createHistoricActivityInstanceQuery().processInstanceId(pi.getId())
        .activityId("provisionHss").singleResult(), "no provisioning after rejection");
  }

  @Test
  void technicalFailureRaisesIncidentAfterRetries() {
    ProcessInstance pi = start("technicalFailure");

    failProvisioningThreeTimes(pi);

    Incident incident = runtime.createIncidentQuery().processInstanceId(pi.getId()).singleResult();
    assertEquals("failedJob", incident.getIncidentType());
    assertEquals("provisionHss", incident.getActivityId());
    assertEquals("HSS provisioning interface timeout", incident.getIncidentMessage());
  }

  @Test
  void operatorFixesVariableAndRetriesIncident() {
    ProcessInstance pi = start("technicalFailure");
    failProvisioningThreeTimes(pi);

    // Operator: correct the data, then retry the incident (Cockpit "Retry" = set retries to 1)
    runtime.setVariable(pi.getId(), "scenario", "success");
    management.setJobRetries(job(pi, "provisionHss").getId(), 1);
    executeJob(pi, "provisionHss");

    assertEquals(0, runtime.createIncidentQuery().processInstanceId(pi.getId()).count(), "incident resolved");
    executeJob(pi, "waitForDonorWindow");
    executeJob(pi, "activateNumber");
    assertEnded(pi, "numberPorted");
  }

  // --- helpers ---

  private ProcessInstance start(String scenario) {
    Map<String, Object> variables = new HashMap<>();
    variables.put("msisdn", "+15550100");
    variables.put("donorOperator", "Operator B");
    variables.put("scenario", scenario);
    return runtime.startProcessInstanceByKey("numberPorting", "+15550100", variables);
  }

  private void failProvisioningThreeTimes(ProcessInstance pi) {
    for (int attempt = 1; attempt <= 3; attempt++) {
      String jobId = job(pi, "provisionHss").getId();
      RuntimeException failure = assertThrows(RuntimeException.class, () -> management.executeJob(jobId));
      assertTrue(failure.getMessage().contains("HSS provisioning interface timeout"));
    }
    assertEquals(0, job(pi, "provisionHss").getRetries(), "retries exhausted");
  }

  private Job job(ProcessInstance pi, String activityId) {
    return management.createJobQuery().processInstanceId(pi.getId()).activityId(activityId).singleResult();
  }

  private void executeJob(ProcessInstance pi, String activityId) {
    management.executeJob(job(pi, activityId).getId());
  }

  private void assertEnded(ProcessInstance pi, String endEventId) {
    assertEquals(0, runtime.createProcessInstanceQuery().processInstanceId(pi.getId()).count(), "instance ended");
    assertEquals(endEventId, history.createHistoricProcessInstanceQuery().processInstanceId(pi.getId())
        .singleResult().getEndActivityId());
  }

  private Object historicVariable(ProcessInstance pi, String name) {
    return history.createHistoricVariableInstanceQuery().processInstanceId(pi.getId())
        .variableName(name).singleResult().getValue();
  }
}
