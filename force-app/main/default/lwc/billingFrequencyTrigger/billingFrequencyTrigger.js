import { LightningElement, api, track } from 'lwc';

export default class BillingFrequencyTrigger extends LightningElement {
    @api recordId;
    @track showModal = false;

    handleOpen() { this.showModal = true; }
    handleClose() { this.showModal = false; }
}
