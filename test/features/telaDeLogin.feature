Feature: Login Page

  @ui @login @success
  Scenario: 01 - Successful login
    Given the user is on the login page
    When the user enters the correct username
    And the user enters the correct password
    And the user clicks the login button
    Then the home page is displayed

  @ui @login @unsuccessful @incorrect-username
  Scenario: 02 - Unsuccessful login - Incorrect username
    Given the user is on the login page
    When the user enters the incorrect username
    And the user enters the correct password
    And the user clicks the login button
    Then an error message is displayed

  @ui @login @unsuccessful @incorrect-password
  Scenario: 03 - Unsuccessful login - Incorrect password
    Given the user is on the login page
    When the user enters the correct username
    And the user enters the incorrect password
    And the user clicks the login button
    Then an error message is displayed
